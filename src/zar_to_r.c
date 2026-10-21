/* Arrow to R (design sections 6.2, 6.3, 6.9): one plan per column decides
   the R form from the type and the lossy policy, a value scan settles the
   columns whose exactness depends on their values, and then each column is
   allocated once and filled from every batch. Nothing here calls back into
   R code: only R's allocators and setters. */
#include <inttypes.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "zar.h"

/* The lossy policy, as R numbers it. */
enum zar_policy {
  ZAR_LOSSY_ERROR = 1,
  ZAR_LOSSY_CHARACTER = 2,
  ZAR_LOSSY_WARN = 3,
  ZAR_LOSSY_ALLOW = 4
};

/* An explicit `to` target, as R numbers it. */
enum zar_to {
  ZAR_TO_NONE = 0,
  ZAR_TO_CHARACTER = 1,
  ZAR_TO_DOUBLE = 2,
  ZAR_TO_INTEGER = 3
};

enum zar_target {
  ZAR_T_NULL,     /* logical, all NA */
  ZAR_T_LGL,
  ZAR_T_INT,
  ZAR_T_DBL,
  ZAR_T_CHR,      /* strings */
  ZAR_T_BLOB,     /* list of raw */
  ZAR_T_DATE,     /* Date, double days */
  ZAR_T_POSIXCT,  /* double seconds */
  ZAR_T_DIFFTIME, /* double seconds */
  ZAR_T_INT64,    /* bit64's integer64: the int64 bits in a double */
  ZAR_T_TEXT      /* the exact canonical text, with arrow_type */
};

/* Which values a scan looks for. */
enum zar_scan {
  ZAR_SCAN_NONE,
  ZAR_SCAN_INT53,    /* |v| > 2^53: a double cannot hold it */
  ZAR_SCAN_UINT53,   /* v > 2^53 */
  ZAR_SCAN_INT32MIN, /* INT_MIN: R's NA_integer_ */
  ZAR_SCAN_INT32,    /* outside int32 without INT_MIN, for to = integer() */
  ZAR_SCAN_NUL       /* an embedded NUL in a string */
};

#define ZAR_2P53 9007199254740992.0

struct zar_plan {
  struct ArrowSchemaView sv;
  const struct ArrowSchema *schema;
  enum zar_target target;
  enum zar_target lossy_target; /* the lossy form under warn or allow */
  enum zar_scan scan;
  int lossy_by_schema;
  int never;   /* no R form at all: intervals, unions */
  int warned;  /* lossy under warn: R emits the warning */
  double per_second;
};

/* ---- scratch: the views, owned by an external pointer ------------------ */

/* The array views live in malloc()ed memory owned by an external pointer
   whose finalizer resets them, so an R allocation that longjmps during
   the fill cannot leak them. */
struct zar_scratch {
  int64_t n;
  struct ArrowArrayView *views;
  struct zar_plan *plans;
};

static void zar_scratch_free(struct zar_scratch *s) {
  if (s->views != NULL) {
    for (int64_t i = 0; i < s->n; i++) ArrowArrayViewReset(&s->views[i]);
    free(s->views);
    s->views = NULL;
  }
  free(s->plans);
  s->plans = NULL;
}

static void zar_scratch_finalize(SEXP xptr) {
  struct zar_scratch *s = (struct zar_scratch *)R_ExternalPtrAddr(xptr);
  if (s != NULL) {
    zar_scratch_free(s);
    free(s);
    R_ClearExternalPtr(xptr);
  }
}

/* ---- failures with fields ---------------------------------------------- */

static SEXP zar_column_failure(const char *kind, const char *message,
                               int column, double row, const char *format,
                               const char *name) {
  const char *names[] = {"kind", "message", "column", "row", "format", "name",
                         ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, names));
  SET_VECTOR_ELT(out, 0, Rf_mkString(kind));
  SET_VECTOR_ELT(out, 1, zar_scalar_utf8(message));
  SET_VECTOR_ELT(out, 2, Rf_ScalarInteger(column));
  SET_VECTOR_ELT(out, 3, Rf_ScalarReal(row));
  SET_VECTOR_ELT(out, 4, zar_scalar_utf8(format == NULL ? "" : format));
  SET_VECTOR_ELT(out, 5, zar_scalar_utf8(name == NULL ? "" : name));
  SEXP cls = PROTECT(Rf_mkString("zar_failure"));
  Rf_setAttrib(out, R_ClassSymbol, cls);
  UNPROTECT(2);
  return out;
}

/* ---- slices ------------------------------------------------------------ */

/* A column of one batch: `view` indexed from `start`, with `parent` the
   struct whose null rows make every child NA (section 6.9). */
struct zar_slice {
  const struct ArrowArrayView *view;
  const struct ArrowArrayView *parent;
  int64_t start;
  int64_t length;
};

static inline int zar_is_null(const struct zar_slice *s, int64_t i) {
  if (s->parent != NULL && ArrowArrayViewIsNull(s->parent, i)) return 1;
  return ArrowArrayViewIsNull(s->view, s->start + i);
}

static inline int zar_has_nulls(const struct zar_slice *s) {
  if (s->parent != NULL && s->parent->null_count != 0) return 1;
  return s->view->null_count != 0;
}

/* ---- planning ---------------------------------------------------------- */

static double zar_units_per_second(enum ArrowTimeUnit unit) {
  switch (unit) {
    case NANOARROW_TIME_UNIT_SECOND:
      return 1.0;
    case NANOARROW_TIME_UNIT_MILLI:
      return 1e3;
    case NANOARROW_TIME_UNIT_MICRO:
      return 1e6;
    default:
      return 1e9;
  }
}

static int zar_has_text_form(enum ArrowType type) {
  switch (type) {
    case NANOARROW_TYPE_INT8:
    case NANOARROW_TYPE_INT16:
    case NANOARROW_TYPE_INT32:
    case NANOARROW_TYPE_INT64:
    case NANOARROW_TYPE_UINT8:
    case NANOARROW_TYPE_UINT16:
    case NANOARROW_TYPE_UINT32:
    case NANOARROW_TYPE_UINT64:
    case NANOARROW_TYPE_DECIMAL32:
    case NANOARROW_TYPE_DECIMAL64:
    case NANOARROW_TYPE_DECIMAL128:
    case NANOARROW_TYPE_DECIMAL256:
    case NANOARROW_TYPE_DATE32:
    case NANOARROW_TYPE_DATE64:
    case NANOARROW_TYPE_TIMESTAMP:
    case NANOARROW_TYPE_TIME32:
    case NANOARROW_TYPE_TIME64:
    case NANOARROW_TYPE_DURATION:
      return 1;
    default:
      return 0;
  }
}

/* Fills the type-driven half of a plan. Returns 0, or EINVAL with `error`
   naming a type this stage cannot convert. */
static int zar_plan_type(struct zar_plan *p, struct ArrowError *error) {
  p->scan = ZAR_SCAN_NONE;
  p->lossy_by_schema = 0;
  p->never = 0;
  p->warned = 0;
  p->per_second = 1.0;
  switch (p->sv.type) {
    case NANOARROW_TYPE_NA:
      p->target = ZAR_T_NULL;
      break;
    case NANOARROW_TYPE_BOOL:
      p->target = ZAR_T_LGL;
      break;
    case NANOARROW_TYPE_INT8:
    case NANOARROW_TYPE_INT16:
    case NANOARROW_TYPE_UINT8:
    case NANOARROW_TYPE_UINT16:
      p->target = ZAR_T_INT;
      break;
    case NANOARROW_TYPE_INT32:
      p->target = ZAR_T_INT;
      p->lossy_target = ZAR_T_INT;
      p->scan = ZAR_SCAN_INT32MIN;
      break;
    case NANOARROW_TYPE_UINT32:
    case NANOARROW_TYPE_HALF_FLOAT:
    case NANOARROW_TYPE_FLOAT:
    case NANOARROW_TYPE_DOUBLE:
      p->target = ZAR_T_DBL;
      break;
    case NANOARROW_TYPE_INT64:
      p->target = ZAR_T_DBL;
      p->lossy_target = ZAR_T_DBL;
      p->scan = ZAR_SCAN_INT53;
      break;
    case NANOARROW_TYPE_UINT64:
      p->target = ZAR_T_DBL;
      p->lossy_target = ZAR_T_DBL;
      p->scan = ZAR_SCAN_UINT53;
      break;
    case NANOARROW_TYPE_STRING:
    case NANOARROW_TYPE_LARGE_STRING:
    case NANOARROW_TYPE_STRING_VIEW:
      p->target = ZAR_T_CHR;
      p->lossy_target = ZAR_T_CHR;
      p->scan = ZAR_SCAN_NUL;
      break;
    case NANOARROW_TYPE_BINARY:
    case NANOARROW_TYPE_LARGE_BINARY:
    case NANOARROW_TYPE_BINARY_VIEW:
    case NANOARROW_TYPE_FIXED_SIZE_BINARY:
      p->target = ZAR_T_BLOB;
      break;
    case NANOARROW_TYPE_DATE32:
      p->target = ZAR_T_DATE;
      break;
    case NANOARROW_TYPE_TIMESTAMP:
      p->per_second = zar_units_per_second(p->sv.time_unit);
      p->target = ZAR_T_POSIXCT;
      p->lossy_target = ZAR_T_POSIXCT;
      if (p->sv.time_unit == NANOARROW_TIME_UNIT_SECOND ||
          p->sv.time_unit == NANOARROW_TIME_UNIT_MILLI) {
        p->scan = ZAR_SCAN_INT53;
      } else {
        p->lossy_by_schema = 1;
      }
      break;
    case NANOARROW_TYPE_DATE64:
      p->per_second = 1e3;
      p->target = ZAR_T_POSIXCT;
      p->lossy_target = ZAR_T_POSIXCT;
      p->lossy_by_schema = 1;
      break;
    case NANOARROW_TYPE_TIME32:
    case NANOARROW_TYPE_TIME64:
    case NANOARROW_TYPE_DURATION:
      p->per_second = zar_units_per_second(p->sv.time_unit);
      p->target = ZAR_T_DIFFTIME;
      p->lossy_target = ZAR_T_DIFFTIME;
      p->lossy_by_schema = 1;
      break;
    case NANOARROW_TYPE_DECIMAL32:
    case NANOARROW_TYPE_DECIMAL64:
    case NANOARROW_TYPE_DECIMAL128:
    case NANOARROW_TYPE_DECIMAL256:
      p->target = ZAR_T_DBL;
      p->lossy_target = ZAR_T_DBL;
      p->lossy_by_schema = 1;
      break;
    case NANOARROW_TYPE_INTERVAL_MONTHS:
    case NANOARROW_TYPE_INTERVAL_DAY_TIME:
    case NANOARROW_TYPE_INTERVAL_MONTH_DAY_NANO:
    case NANOARROW_TYPE_SPARSE_UNION:
    case NANOARROW_TYPE_DENSE_UNION:
      p->never = 1;
      p->lossy_by_schema = 1;
      p->target = ZAR_T_NULL;
      break;
    default:
      ArrowErrorSet(error, "converting %s columns is not supported yet",
                    ArrowTypeString(p->sv.type));
      return EINVAL;
  }
  return NANOARROW_OK;
}

/* Applies an explicit `to` target. Returns 0, or EINVAL when the target
   cannot take the column. */
static int zar_plan_to(struct zar_plan *p, int to, struct ArrowError *error) {
  enum ArrowType t = p->sv.type;
  switch (to) {
    case ZAR_TO_NONE:
      return NANOARROW_OK;
    case ZAR_TO_CHARACTER:
      if (p->target == ZAR_T_CHR) return NANOARROW_OK;
      if (!zar_has_text_form(t)) break;
      p->target = ZAR_T_TEXT;
      p->scan = ZAR_SCAN_NONE;
      p->lossy_by_schema = 0;
      return NANOARROW_OK;
    case ZAR_TO_DOUBLE:
      if (p->target == ZAR_T_DBL ||
          (p->target == ZAR_T_INT && t != NANOARROW_TYPE_BOOL)) {
        if (t == NANOARROW_TYPE_INT32) p->scan = ZAR_SCAN_NONE;
        p->target = ZAR_T_DBL;
        p->lossy_target = ZAR_T_DBL;
        return NANOARROW_OK;
      }
      break;
    case ZAR_TO_INTEGER:
      if (p->target == ZAR_T_INT) return NANOARROW_OK;
      if (t == NANOARROW_TYPE_UINT32 || t == NANOARROW_TYPE_INT64 ||
          t == NANOARROW_TYPE_UINT64) {
        p->target = ZAR_T_INT;
        p->lossy_target = ZAR_T_INT;
        p->scan = ZAR_SCAN_INT32;
        return NANOARROW_OK;
      }
      break;
    default:
      break;
  }
  ArrowErrorSet(error, "the requested R type cannot hold a %s column",
                ArrowTypeString(t));
  return EINVAL;
}

/* ---- the value scan ---------------------------------------------------- */

/* Returns the first offending element of the slice, or -1. */
static int64_t zar_scan_slice(const struct zar_plan *p,
                              const struct zar_slice *s) {
  for (int64_t i = 0; i < s->length; i++) {
    if (zar_is_null(s, i)) continue;
    int64_t j = s->start + i;
    switch (p->scan) {
      case ZAR_SCAN_INT53: {
        int64_t v = ArrowArrayViewGetIntUnsafe(s->view, j);
        if (v > 9007199254740992LL || v < -9007199254740992LL) return i;
        break;
      }
      case ZAR_SCAN_UINT53: {
        uint64_t v = ArrowArrayViewGetUIntUnsafe(s->view, j);
        if (v > 9007199254740992ULL) return i;
        break;
      }
      case ZAR_SCAN_INT32MIN:
        if (ArrowArrayViewGetIntUnsafe(s->view, j) == INT32_MIN) return i;
        break;
      case ZAR_SCAN_INT32: {
        if (s->view->storage_type == NANOARROW_TYPE_UINT64) {
          if (ArrowArrayViewGetUIntUnsafe(s->view, j) > INT32_MAX) return i;
        } else {
          int64_t v = ArrowArrayViewGetIntUnsafe(s->view, j);
          if (v > INT32_MAX || v <= INT32_MIN) return i;
        }
        break;
      }
      case ZAR_SCAN_NUL: {
        struct ArrowBufferView b = ArrowArrayViewGetBytesUnsafe(s->view, j);
        if (b.size_bytes > 0 && memchr(b.data.data, 0, (size_t)b.size_bytes)) {
          return i;
        }
        break;
      }
      default:
        return -1;
    }
  }
  return -1;
}

static void zar_describe_value(const struct zar_plan *p,
                               const struct zar_slice *s, int64_t i, char *out,
                               size_t n) {
  int64_t j = s->start + i;
  switch (p->scan) {
    case ZAR_SCAN_UINT53:
      snprintf(out, n, "%" PRIu64, ArrowArrayViewGetUIntUnsafe(s->view, j));
      break;
    case ZAR_SCAN_NUL:
      snprintf(out, n, "a string with an embedded NUL");
      break;
    case ZAR_SCAN_INT32:
      if (s->view->storage_type == NANOARROW_TYPE_UINT64) {
        snprintf(out, n, "%" PRIu64, ArrowArrayViewGetUIntUnsafe(s->view, j));
        break;
      }
      snprintf(out, n, "%" PRId64, ArrowArrayViewGetIntUnsafe(s->view, j));
      break;
    default:
      snprintf(out, n, "%" PRId64, ArrowArrayViewGetIntUnsafe(s->view, j));
      break;
  }
}

/* ---- text forms -------------------------------------------------------- */

/* Days since 1970-01-01 to a civil date (H. Hinnant's algorithm). */
static void zar_civil(int64_t days, int64_t *y, int *m, int *d) {
  days += 719468;
  int64_t era = (days >= 0 ? days : days - 146096) / 146097;
  int64_t doe = days - era * 146097;
  int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  int64_t mp = (5 * doy + 2) / 153;
  *d = (int)(doy - (153 * mp + 2) / 5 + 1);
  *m = (int)(mp < 10 ? mp + 3 : mp - 9);
  *y = yoe + era * 400 + (*m <= 2);
}

static int64_t zar_floor_div(int64_t a, int64_t b) {
  int64_t q = a / b;
  if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
  return q;
}

static int zar_unit_digits(enum ArrowTimeUnit unit) {
  switch (unit) {
    case NANOARROW_TIME_UNIT_SECOND:
      return 0;
    case NANOARROW_TIME_UNIT_MILLI:
      return 3;
    case NANOARROW_TIME_UNIT_MICRO:
      return 6;
    default:
      return 9;
  }
}

static int64_t zar_unit_scale(int digits) {
  int64_t s = 1;
  for (int k = 0; k < digits; k++) s *= 10;
  return s;
}

/* ISO 8601: YYYY-MM-DD, with a sign and more digits outside 0000-9999. */
static int zar_format_date(char *out, size_t n, int64_t days) {
  int64_t y;
  int m, d;
  zar_civil(days, &y, &m, &d);
  if (y >= 0 && y <= 9999) {
    return snprintf(out, n, "%04" PRId64 "-%02d-%02d", y, m, d);
  }
  return snprintf(out, n, "%+05" PRId64 "-%02d-%02d", y, m, d);
}

static void zar_format_instant(char *out, size_t n, int64_t value, int digits,
                               int utc) {
  int64_t scale = zar_unit_scale(digits);
  int64_t secs = zar_floor_div(value, scale);
  int64_t frac = value - secs * scale;
  int64_t days = zar_floor_div(secs, 86400);
  int64_t sod = secs - days * 86400;
  int len = zar_format_date(out, n, days);
  len += snprintf(out + len, n - (size_t)len, "T%02d:%02d:%02d",
                  (int)(sod / 3600), (int)(sod / 60 % 60), (int)(sod % 60));
  if (digits > 0) {
    len += snprintf(out + len, n - (size_t)len, ".%0*" PRId64, digits, frac);
  }
  if (utc) snprintf(out + len, n - (size_t)len, "Z");
}

static void zar_format_time(char *out, size_t n, int64_t value, int digits) {
  int64_t scale = zar_unit_scale(digits);
  const char *sign = value < 0 ? "-" : "";
  uint64_t v = value < 0 ? (uint64_t)(-(value + 1)) + 1 : (uint64_t)value;
  uint64_t secs = v / (uint64_t)scale;
  uint64_t frac = v % (uint64_t)scale;
  int len = snprintf(out, n, "%s%02" PRIu64 ":%02d:%02d", sign, secs / 3600,
                     (int)(secs / 60 % 60), (int)(secs % 60));
  if (digits > 0) {
    snprintf(out + len, n - (size_t)len, ".%0*" PRIu64, digits, frac);
  }
}

/* Writes the canonical text of element j, or returns ENOMEM. */
static int zar_text(const struct zar_plan *p, const struct ArrowArrayView *v,
                    int64_t j, struct ArrowBuffer *scratch, char *buf,
                    size_t n, const char **out) {
  *out = buf;
  switch (p->sv.type) {
    case NANOARROW_TYPE_UINT8:
    case NANOARROW_TYPE_UINT16:
    case NANOARROW_TYPE_UINT32:
    case NANOARROW_TYPE_UINT64:
      snprintf(buf, n, "%" PRIu64, ArrowArrayViewGetUIntUnsafe(v, j));
      return NANOARROW_OK;
    case NANOARROW_TYPE_INT8:
    case NANOARROW_TYPE_INT16:
    case NANOARROW_TYPE_INT32:
    case NANOARROW_TYPE_INT64:
    case NANOARROW_TYPE_DURATION:
      snprintf(buf, n, "%" PRId64, ArrowArrayViewGetIntUnsafe(v, j));
      return NANOARROW_OK;
    case NANOARROW_TYPE_DATE32:
      zar_format_date(buf, n, ArrowArrayViewGetIntUnsafe(v, j));
      return NANOARROW_OK;
    case NANOARROW_TYPE_DATE64:
      zar_format_instant(buf, n, ArrowArrayViewGetIntUnsafe(v, j), 3, 1);
      return NANOARROW_OK;
    case NANOARROW_TYPE_TIMESTAMP:
      zar_format_instant(buf, n, ArrowArrayViewGetIntUnsafe(v, j),
                         zar_unit_digits(p->sv.time_unit),
                         p->sv.timezone != NULL && p->sv.timezone[0] != '\0');
      return NANOARROW_OK;
    case NANOARROW_TYPE_TIME32:
    case NANOARROW_TYPE_TIME64:
      zar_format_time(buf, n, ArrowArrayViewGetIntUnsafe(v, j),
                      zar_unit_digits(p->sv.time_unit));
      return NANOARROW_OK;
    case NANOARROW_TYPE_DECIMAL32:
    case NANOARROW_TYPE_DECIMAL64:
    case NANOARROW_TYPE_DECIMAL128:
    case NANOARROW_TYPE_DECIMAL256: {
      struct ArrowDecimal dec;
      ArrowDecimalInit(&dec, p->sv.decimal_bitwidth, p->sv.decimal_precision,
                       p->sv.decimal_scale);
      ArrowArrayViewGetDecimalUnsafe(v, j, &dec);
      scratch->size_bytes = 0;
      if (ArrowDecimalAppendStringToBuffer(&dec, scratch) != NANOARROW_OK ||
          ArrowBufferAppendInt8(scratch, 0) != NANOARROW_OK) {
        return ENOMEM;
      }
      *out = (const char *)scratch->data;
      return NANOARROW_OK;
    }
    default:
      buf[0] = '\0';
      return NANOARROW_OK;
  }
}

/* ---- half floats ------------------------------------------------------- */

/* IEEE 754 binary16 to double, exactly, subnormals included. nanoarrow's
   ArrowHalfFloatToFloat flushes the subnormal exponent wrongly, so the
   widening is done here (design section 6.2). */
static double zar_half_to_double(uint16_t h) {
  int sign = (h >> 15) & 1;
  int exp = (h >> 10) & 0x1f;
  int frac = h & 0x3ff;
  double v;
  if (exp == 0) {
    v = ldexp((double)frac, -24);
  } else if (exp == 0x1f) {
    v = frac == 0 ? R_PosInf : R_NaN;
  } else {
    v = ldexp((double)(frac | 0x400), exp - 25);
  }
  return sign ? -v : v;
}

/* ---- fill -------------------------------------------------------------- */

static int zar_fill(const struct zar_plan *p, const struct zar_slice *s,
                    SEXP out, R_xlen_t at, struct ArrowBuffer *scratch,
                    struct ArrowError *error) {
  const struct ArrowArrayView *v = s->view;
  int64_t n = s->length;
  switch (p->target) {
    case ZAR_T_NULL:
    case ZAR_T_LGL: {
      int *dst = LOGICAL(out) + at;
      for (int64_t i = 0; i < n; i++) {
        dst[i] = (p->target == ZAR_T_NULL || zar_is_null(s, i))
                     ? NA_LOGICAL
                     : (int)ArrowArrayViewGetIntUnsafe(v, s->start + i);
      }
      return NANOARROW_OK;
    }
    case ZAR_T_INT: {
      int *dst = INTEGER(out) + at;
      if (n == 0) return NANOARROW_OK;
      if (v->storage_type == NANOARROW_TYPE_INT32 && !zar_has_nulls(s)) {
        memcpy(dst, v->buffer_views[1].data.as_int32 + v->offset + s->start,
               (size_t)n * sizeof(int32_t));
        return NANOARROW_OK;
      }
      for (int64_t i = 0; i < n; i++) {
        if (zar_is_null(s, i)) {
          dst[i] = NA_INTEGER;
          continue;
        }
        if (v->storage_type == NANOARROW_TYPE_UINT64) {
          uint64_t u = ArrowArrayViewGetUIntUnsafe(v, s->start + i);
          dst[i] = u > INT32_MAX ? NA_INTEGER : (int)u;
        } else {
          int64_t x = ArrowArrayViewGetIntUnsafe(v, s->start + i);
          dst[i] = (x > INT32_MAX || x < INT32_MIN) ? NA_INTEGER : (int)x;
        }
      }
      return NANOARROW_OK;
    }
    case ZAR_T_DBL: {
      double *dst = REAL(out) + at;
      enum ArrowType t = v->storage_type;
      if (n == 0) return NANOARROW_OK;
      if (t == NANOARROW_TYPE_DOUBLE && !zar_has_nulls(s)) {
        memcpy(dst, v->buffer_views[1].data.as_double + v->offset + s->start,
               (size_t)n * sizeof(double));
        return NANOARROW_OK;
      }
      int decimal = p->sv.type == NANOARROW_TYPE_DECIMAL32 ||
                    p->sv.type == NANOARROW_TYPE_DECIMAL64 ||
                    p->sv.type == NANOARROW_TYPE_DECIMAL128 ||
                    p->sv.type == NANOARROW_TYPE_DECIMAL256;
      char buf[16];
      for (int64_t i = 0; i < n; i++) {
        int64_t j = s->start + i;
        if (zar_is_null(s, i)) {
          dst[i] = NA_REAL;
        } else if (decimal) {
          const char *text;
          if (zar_text(p, v, j, scratch, buf, sizeof(buf), &text) !=
              NANOARROW_OK) {
            ArrowErrorSet(error, "cannot allocate a decimal's text");
            return ENOMEM;
          }
          dst[i] = R_strtod(text, NULL);
        } else if (t == NANOARROW_TYPE_HALF_FLOAT) {
          dst[i] = zar_half_to_double(v->buffer_views[1].data.as_uint16[v->offset + j]);
        } else if (t == NANOARROW_TYPE_DOUBLE || t == NANOARROW_TYPE_FLOAT) {
          dst[i] = ArrowArrayViewGetDoubleUnsafe(v, j);
        } else if (t == NANOARROW_TYPE_UINT64 || t == NANOARROW_TYPE_UINT32 ||
                   t == NANOARROW_TYPE_UINT16 || t == NANOARROW_TYPE_UINT8) {
          dst[i] = (double)ArrowArrayViewGetUIntUnsafe(v, j);
        } else {
          dst[i] = (double)ArrowArrayViewGetIntUnsafe(v, j);
        }
      }
      return NANOARROW_OK;
    }
    case ZAR_T_DATE:
    case ZAR_T_POSIXCT:
    case ZAR_T_DIFFTIME: {
      double *dst = REAL(out) + at;
      double scale = p->target == ZAR_T_DATE ? 1.0 : p->per_second;
      for (int64_t i = 0; i < n; i++) {
        dst[i] = zar_is_null(s, i)
                     ? NA_REAL
                     : (double)ArrowArrayViewGetIntUnsafe(v, s->start + i) /
                           scale;
      }
      return NANOARROW_OK;
    }
    case ZAR_T_INT64: {
      int64_t *dst = (int64_t *)REAL(out) + at;
      for (int64_t i = 0; i < n; i++) {
        /* bit64's NA is INT64_MIN. */
        dst[i] = zar_is_null(s, i) ? INT64_MIN
                                   : ArrowArrayViewGetIntUnsafe(v, s->start + i);
      }
      return NANOARROW_OK;
    }
    case ZAR_T_CHR: {
      for (int64_t i = 0; i < n; i++) {
        if (zar_is_null(s, i)) {
          SET_STRING_ELT(out, at + (R_xlen_t)i, NA_STRING);
          continue;
        }
        struct ArrowBufferView b = ArrowArrayViewGetBytesUnsafe(v, s->start + i);
        int64_t len = b.size_bytes;
        const char *nul = len > 0 ? memchr(b.data.data, 0, (size_t)len) : NULL;
        if (nul != NULL) len = nul - b.data.as_char;
        if (zar_utf8_invalid_at(b.data.as_uint8, len) >= 0) {
          ArrowErrorSet(error, "element %ld is not valid UTF-8", (long)i);
          return EINVAL;
        }
        if (len > INT_MAX) {
          ArrowErrorSet(error, "element %ld is longer than R's string limit",
                        (long)i);
          return EINVAL;
        }
        SET_STRING_ELT(out, at + (R_xlen_t)i,
                       len == 0 ? R_BlankString
                                : Rf_mkCharLenCE(b.data.as_char, (int)len, CE_UTF8));
      }
      return NANOARROW_OK;
    }
    case ZAR_T_BLOB: {
      for (int64_t i = 0; i < n; i++) {
        if (zar_is_null(s, i)) continue;
        struct ArrowBufferView b = ArrowArrayViewGetBytesUnsafe(v, s->start + i);
        SEXP raw = Rf_allocVector(RAWSXP, (R_xlen_t)b.size_bytes);
        SET_VECTOR_ELT(out, at + (R_xlen_t)i, raw);
        if (b.size_bytes > 0) {
          memcpy(RAW(raw), b.data.data, (size_t)b.size_bytes);
        }
      }
      return NANOARROW_OK;
    }
    case ZAR_T_TEXT: {
      char buf[96];
      for (int64_t i = 0; i < n; i++) {
        if (zar_is_null(s, i)) {
          SET_STRING_ELT(out, at + (R_xlen_t)i, NA_STRING);
          continue;
        }
        const char *text;
        if (zar_text(p, v, s->start + i, scratch, buf, sizeof(buf), &text) !=
            NANOARROW_OK) {
          ArrowErrorSet(error, "cannot allocate a decimal's text");
          return ENOMEM;
        }
        SET_STRING_ELT(out, at + (R_xlen_t)i, Rf_mkCharCE(text, CE_UTF8));
      }
      return NANOARROW_OK;
    }
  }
  return NANOARROW_OK;
}

static SEXP zar_alloc(const struct zar_plan *p, R_xlen_t n) {
  switch (p->target) {
    case ZAR_T_NULL:
    case ZAR_T_LGL:
      return Rf_allocVector(LGLSXP, n);
    case ZAR_T_INT:
      return Rf_allocVector(INTSXP, n);
    case ZAR_T_CHR:
    case ZAR_T_TEXT:
      return Rf_allocVector(STRSXP, n);
    case ZAR_T_BLOB:
      return Rf_allocVector(VECSXP, n);
    default:
      return Rf_allocVector(REALSXP, n);
  }
}

static void zar_set_class(SEXP x, const char *a, const char *b) {
  SEXP cls = PROTECT(Rf_allocVector(STRSXP, b == NULL ? 1 : 2));
  SET_STRING_ELT(cls, 0, Rf_mkChar(a));
  if (b != NULL) SET_STRING_ELT(cls, 1, Rf_mkChar(b));
  Rf_setAttrib(x, R_ClassSymbol, cls);
  UNPROTECT(1);
}

static void zar_set_string_attr(SEXP x, const char *name, const char *value) {
  SEXP v = PROTECT(zar_scalar_utf8(value));
  Rf_setAttrib(x, Rf_install(name), v);
  UNPROTECT(1);
}

static void zar_decorate(const struct zar_plan *p, SEXP x) {
  switch (p->target) {
    case ZAR_T_DATE:
      zar_set_class(x, "Date", NULL);
      break;
    case ZAR_T_POSIXCT: {
      zar_set_class(x, "POSIXct", "POSIXt");
      const char *tz = p->sv.type == NANOARROW_TYPE_DATE64 ? "UTC"
                       : p->sv.timezone == NULL           ? ""
                                                          : p->sv.timezone;
      zar_set_string_attr(x, "tzone", tz);
      break;
    }
    case ZAR_T_DIFFTIME:
      zar_set_class(x, "difftime", NULL);
      zar_set_string_attr(x, "units", "secs");
      break;
    case ZAR_T_INT64:
      zar_set_class(x, "integer64", NULL);
      break;
    case ZAR_T_TEXT:
      zar_set_string_attr(x, "arrow_type", p->schema->format);
      if (p->sv.type == NANOARROW_TYPE_DURATION) {
        const char *units[] = {"s", "ms", "us", "ns"};
        zar_set_string_attr(x, "arrow_unit", units[p->sv.time_unit]);
      }
      break;
    case ZAR_T_BLOB:
      if (p->sv.type == NANOARROW_TYPE_FIXED_SIZE_BINARY) {
        SEXP w = PROTECT(Rf_ScalarInteger(p->sv.fixed_size));
        Rf_setAttrib(x, Rf_install("arrow_width"), w);
        UNPROTECT(1);
      }
      break;
    default:
      break;
  }
}

/* ---- the entry point --------------------------------------------------- */

/* Converts the batches in `arrays` (array handles of one schema) to R.
   With `frame` TRUE the schema is a struct and each field is a column;
   otherwise the array itself is the one column. `opts` is
   list(lossy, to, int64, frame): `to` an integer code per column, `int64`
   whether bit64's integer64 may be used.

   Returns list(columns, names, warned, rows), or a failure with the
   column, row, format and name. */
SEXP zar_c_to_r(SEXP arrays, SEXP schema_xptr, SEXP opts) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowSchema *schema = zar_schema_from_xptr(schema_xptr, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);

  int lossy = Rf_asInteger(VECTOR_ELT(opts, 0));
  SEXP to = VECTOR_ELT(opts, 1);
  int int64_ok = Rf_asLogical(VECTOR_ELT(opts, 2));
  int frame = Rf_asLogical(VECTOR_ELT(opts, 3));

  R_xlen_t n_batches = Rf_xlength(arrays);
  for (R_xlen_t b = 0; b < n_batches; b++) {
    if (zar_array_from_xptr(VECTOR_ELT(arrays, b), &error) == NULL) {
      return zar_failure_from_error("handle", &error);
    }
  }

  struct ArrowSchemaView top;
  if (ArrowSchemaViewInit(&top, schema, &error) != NANOARROW_OK) {
    return zar_failure_from_error("format", &error);
  }
  if (frame && top.type != NANOARROW_TYPE_STRUCT) {
    return zar_failure("type", "a data frame needs a struct schema");
  }
  int64_t n_cols = frame ? schema->n_children : 1;

  /* The scratch owns the views and plans from here on. */
  SEXP scratch_xptr = PROTECT(R_MakeExternalPtr(NULL, R_NilValue, R_NilValue));
  R_RegisterCFinalizer(scratch_xptr, &zar_scratch_finalize);
  struct zar_scratch *sc =
      (struct zar_scratch *)calloc(1, sizeof(struct zar_scratch));
  if (sc == NULL) {
    UNPROTECT(1);
    return zar_failure(NULL, "cannot allocate conversion scratch");
  }
  R_SetExternalPtrAddr(scratch_xptr, sc);
  sc->views = (struct ArrowArrayView *)calloc(
      n_batches > 0 ? (size_t)n_batches : 1, sizeof(struct ArrowArrayView));
  sc->plans = (struct zar_plan *)calloc(n_cols > 0 ? (size_t)n_cols : 1,
                                        sizeof(struct zar_plan));
  if (sc->views == NULL || sc->plans == NULL) {
    UNPROTECT(1);
    return zar_failure(NULL, "cannot allocate conversion scratch");
  }

  int64_t rows = 0;
  for (R_xlen_t b = 0; b < n_batches; b++) {
    struct ArrowArray *array =
        (struct ArrowArray *)R_ExternalPtrAddr(VECTOR_ELT(arrays, b));
    int code = ArrowArrayViewInitFromSchema(&sc->views[b], schema, &error);
    sc->n = (int64_t)b + 1;
    if (code == NANOARROW_OK) {
      code = ArrowArrayViewSetArray(&sc->views[b], array, &error);
    }
    if (code != NANOARROW_OK) {
      UNPROTECT(1);
      return zar_failure_from_error("format", &error);
    }
    rows += sc->views[b].length;
  }
  if (rows > R_XLEN_T_MAX) {
    UNPROTECT(1);
    return zar_failure("limit", "the batches hold more rows than R allows");
  }

  /* Plan, then scan. */
  for (int64_t c = 0; c < n_cols; c++) {
    struct zar_plan *p = &sc->plans[c];
    p->schema = frame ? schema->children[c] : schema;
    const char *name = p->schema->name;
    if (ArrowSchemaViewInit(&p->sv, p->schema, &error) != NANOARROW_OK) {
      UNPROTECT(1);
      return zar_column_failure("format", error.message, (int)c + 1, NA_REAL,
                                p->schema->format, name);
    }
    int code = zar_plan_type(p, &error);
    int target_to = Rf_xlength(to) > c ? INTEGER(to)[c] : ZAR_TO_NONE;
    if (code == NANOARROW_OK) code = zar_plan_to(p, target_to, &error);
    if (code != NANOARROW_OK) {
      UNPROTECT(1);
      return zar_column_failure("type", error.message, (int)c + 1, NA_REAL,
                                p->schema->format, name);
    }

    if (p->sv.type == NANOARROW_TYPE_INT64 && lossy == ZAR_LOSSY_ALLOW &&
        int64_ok && target_to == ZAR_TO_NONE) {
      p->target = ZAR_T_INT64;
      p->scan = ZAR_SCAN_NONE;
      continue;
    }

    if (p->never) {
      ArrowErrorSet(&error, "%s has no R form", ArrowTypeString(p->sv.type));
      UNPROTECT(1);
      return zar_column_failure("lossy", error.message, (int)c + 1, NA_REAL,
                                p->schema->format, name);
    }

    int64_t bad_row = -1;
    char value[64] = "";
    if (p->lossy_by_schema) {
      bad_row = -2;
    } else if (p->scan != ZAR_SCAN_NONE) {
      int64_t offset = 0;
      for (R_xlen_t b = 0; b < n_batches && bad_row < 0; b++) {
        const struct ArrowArrayView *bv = &sc->views[b];
        struct zar_slice s = frame ? (struct zar_slice){bv->children[c], bv,
                                                        bv->offset, bv->length}
                                   : (struct zar_slice){bv, NULL, 0, bv->length};
        int64_t i = zar_scan_slice(p, &s);
        if (i >= 0) {
          bad_row = offset + i;
          zar_describe_value(p, &s, i, value, sizeof(value));
        }
        offset += bv->length;
      }
    }
    if (bad_row == -1) continue;

    /* Lossy, by schema (-2) or at bad_row. */
    int text_ok = zar_has_text_form(p->sv.type) && p->scan != ZAR_SCAN_NUL;
    if (lossy == ZAR_LOSSY_CHARACTER && text_ok) {
      p->target = ZAR_T_TEXT;
    } else if (lossy == ZAR_LOSSY_WARN || lossy == ZAR_LOSSY_ALLOW) {
      p->target = p->lossy_target;
      p->warned = lossy == ZAR_LOSSY_WARN;
    } else {
      if (bad_row >= 0) {
        ArrowErrorSet(&error, "row %ld holds %s", (long)(bad_row + 1), value);
      } else {
        ArrowErrorSet(&error, "%s has no exact R form here",
                      ArrowTypeString(p->sv.type));
      }
      UNPROTECT(1);
      return zar_column_failure(
          "lossy", error.message, (int)c + 1,
          bad_row >= 0 ? (double)(bad_row + 1) : NA_REAL, p->schema->format,
          name);
    }
  }

  /* Allocate and fill. */
  SEXP columns = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n_cols));
  SEXP names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)n_cols));
  struct ArrowBuffer text;
  ArrowBufferInit(&text);
  for (int64_t c = 0; c < n_cols; c++) {
    struct zar_plan *p = &sc->plans[c];
    SET_STRING_ELT(names, (R_xlen_t)c,
                   Rf_mkCharCE(p->schema->name == NULL ? "" : p->schema->name,
                               CE_UTF8));
    SEXP col = zar_alloc(p, (R_xlen_t)rows);
    SET_VECTOR_ELT(columns, (R_xlen_t)c, col);
    R_xlen_t at = 0;
    for (R_xlen_t b = 0; b < n_batches; b++) {
      const struct ArrowArrayView *bv = &sc->views[b];
      struct zar_slice s = frame ? (struct zar_slice){bv->children[c], bv,
                                                      bv->offset, bv->length}
                                 : (struct zar_slice){bv, NULL, 0, bv->length};
      if (zar_fill(p, &s, col, at, &text, &error) != NANOARROW_OK) {
        ArrowBufferReset(&text);
        UNPROTECT(3);
        return zar_column_failure("format", error.message, (int)c + 1,
                                  NA_REAL, p->schema->format, p->schema->name);
      }
      at += (R_xlen_t)bv->length;
    }
    zar_decorate(p, col);
  }
  ArrowBufferReset(&text);

  int n_warned = 0;
  for (int64_t c = 0; c < n_cols; c++) n_warned += sc->plans[c].warned;
  SEXP warned = PROTECT(Rf_allocVector(INTSXP, n_warned));
  for (int64_t c = 0, k = 0; c < n_cols; c++) {
    if (sc->plans[c].warned) INTEGER(warned)[k++] = (int)c + 1;
  }

  const char *out_names[] = {"columns", "names", "warned", "rows", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, out_names));
  SET_VECTOR_ELT(out, 0, columns);
  SET_VECTOR_ELT(out, 1, names);
  SET_VECTOR_ELT(out, 2, warned);
  SET_VECTOR_ELT(out, 3, Rf_ScalarReal((double)rows));

  zar_scratch_free(sc);
  UNPROTECT(5);
  return out;
}
