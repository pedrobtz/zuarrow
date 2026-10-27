/* R to Arrow (design sections 6.2, 6.9): builds an array of a given schema
   from rows [start, start + n) of an R vector or data frame, writing
   buffers directly. Every NA becomes a null bit over a zeroed slot. A value
   the schema cannot hold exactly is reported, never rounded, except that
   POSIXct and difftime round to the schema's unit (D10). */
#include <inttypes.h>
#include <math.h>
#include <string.h>

#include "zar.h"

#define ZAR_MAX_PREBUILT 256

struct zar_build {
  struct ArrowError error;
  const char *kind; /* the failure's kind when a build fails */
  double row;       /* 1-based, or NA */
  /* Arrays a registered handler built, swapped into their slots once the
     rest is finished, since nanoarrow's finishing walks every child's
     private data as its own. */
  int n_prebuilt;
  struct ArrowArray *slots[ZAR_MAX_PREBUILT];
  SEXP sources[ZAR_MAX_PREBUILT];
};

static int zar_build_fail(struct zar_build *b, const char *kind, double row) {
  b->kind = kind;
  b->row = row;
  return EINVAL;
}

/* ---- validity ---------------------------------------------------------- */

typedef int (*zar_is_na_fn)(SEXP x, R_xlen_t i);

static int zar_na_lgl(SEXP x, R_xlen_t i) { return LOGICAL(x)[i] == NA_LOGICAL; }
static int zar_na_int(SEXP x, R_xlen_t i) { return INTEGER(x)[i] == NA_INTEGER; }
static int zar_na_dbl(SEXP x, R_xlen_t i) { return R_IsNA(REAL(x)[i]); }
static int zar_na_chr(SEXP x, R_xlen_t i) { return STRING_ELT(x, i) == NA_STRING; }
static int zar_na_list(SEXP x, R_xlen_t i) { return VECTOR_ELT(x, i) == R_NilValue; }
static int zar_na_lgl_true(SEXP x, R_xlen_t i) { return LOGICAL(x)[i] == TRUE; }

/* Writes the validity bitmap of rows [start, start + n) when any is NA. */
/* Counts the NAs of an integer, logical or double vector through a typed
   pointer, and writes the bitmap a byte at a time: no call per element. */
#define ZAR_VALIDITY(CTYPE, PTR, IS_NA)                                   \
  {                                                                       \
    const CTYPE *src = PTR(x) + start;                                    \
    int64_t nulls = 0;                                                    \
    for (int64_t i = 0; i < n; i++) nulls += IS_NA(src[i]);               \
    array->null_count = nulls;                                            \
    if (nulls == 0) return NANOARROW_OK;                                  \
    struct ArrowBitmap *bitmap = ArrowArrayValidityBitmap(array);         \
    if (ArrowBitmapReserve(bitmap, n) != NANOARROW_OK) {                  \
      ArrowErrorSet(&b->error, "cannot allocate a validity bitmap");     \
      return zar_build_fail(b, NULL, NA_REAL);                            \
    }                                                                     \
    uint8_t *bits = bitmap->buffer.data;                                  \
    memset(bits, 0, (size_t)((n + 7) / 8));                               \
    for (int64_t i = 0; i < n; i++) {                                     \
      bits[i >> 3] |= (uint8_t)(!IS_NA(src[i]) << (i & 7));               \
    }                                                                     \
    bitmap->size_bits = n;                                                \
    bitmap->buffer.size_bytes = (n + 7) / 8;                              \
    return NANOARROW_OK;                                                  \
  }
#define ZAR_NA_INT(v) ((v) == NA_INTEGER)
#define ZAR_NA_DBL(v) (ISNAN(v) && R_IsNA(v))

static int zar_set_validity(struct ArrowArray *array, SEXP x, R_xlen_t start,
                            int64_t n, zar_is_na_fn is_na,
                            struct zar_build *b) {
  if (n > 0 && (is_na == zar_na_int || is_na == zar_na_lgl)) {
    if (TYPEOF(x) == LGLSXP) ZAR_VALIDITY(int, LOGICAL, ZAR_NA_INT)
    ZAR_VALIDITY(int, INTEGER, ZAR_NA_INT)
  }
  if (n > 0 && is_na == zar_na_dbl) ZAR_VALIDITY(double, REAL, ZAR_NA_DBL)
  int64_t nulls = 0;
  for (int64_t i = 0; i < n; i++) nulls += is_na(x, start + (R_xlen_t)i);
  array->null_count = nulls;
  if (nulls == 0) return NANOARROW_OK;
  struct ArrowBitmap *bitmap = ArrowArrayValidityBitmap(array);
  if (ArrowBitmapReserve(bitmap, n) != NANOARROW_OK) {
    ArrowErrorSet(&b->error, "cannot allocate a validity bitmap");
    return zar_build_fail(b, NULL, NA_REAL);
  }
  for (int64_t i = 0; i < n; i++) {
    ArrowBitmapAppendUnsafe(bitmap, !is_na(x, start + (R_xlen_t)i), 1);
  }
  return NANOARROW_OK;
}

/* Appends `bytes` bytes to buffer i and returns where they start: left as
   they are by zar_data_uninit(), for a caller that writes every one, and
   zeroed by zar_data(). Zero bytes leave an unallocated buffer alone and
   return a pointer that is never written through, since pointer arithmetic
   on NULL is undefined. */
static void *zar_data_uninit(struct ArrowArray *array, int i, int64_t bytes,
                             struct zar_build *b) {
  static uint8_t nothing[8];
  if (bytes == 0) return nothing;
  struct ArrowBuffer *buffer = ArrowArrayBuffer(array, i);
  if (ArrowBufferReserve(buffer, bytes) != NANOARROW_OK) {
    ArrowErrorSet(&b->error, "cannot allocate %" PRId64 " bytes", bytes);
    return NULL;
  }
  void *out = buffer->data + buffer->size_bytes;
  buffer->size_bytes += bytes;
  return out;
}

static void *zar_data(struct ArrowArray *array, int i, int64_t bytes,
                      struct zar_build *b) {
  void *out = zar_data_uninit(array, i, bytes, b);
  if (out != NULL && bytes > 0) memset(out, 0, (size_t)bytes);
  return out;
}

/* ---- numbers ----------------------------------------------------------- */

static int zar_int_fits(enum ArrowType t, double v) {
  switch (t) {
    case NANOARROW_TYPE_INT8:
      return v >= INT8_MIN && v <= INT8_MAX;
    case NANOARROW_TYPE_INT16:
      return v >= INT16_MIN && v <= INT16_MAX;
    case NANOARROW_TYPE_INT32:
      return v >= INT32_MIN && v <= INT32_MAX;
    case NANOARROW_TYPE_INT64:
      return v >= -9223372036854775808.0 && v < 9223372036854775808.0;
    case NANOARROW_TYPE_UINT8:
      return v >= 0 && v <= UINT8_MAX;
    case NANOARROW_TYPE_UINT16:
      return v >= 0 && v <= UINT16_MAX;
    case NANOARROW_TYPE_UINT32:
      return v >= 0 && v <= UINT32_MAX;
    case NANOARROW_TYPE_UINT64:
      return v >= 0 && v < 18446744073709551616.0;
    default:
      return 0;
  }
}

static void zar_store_int(void *data, enum ArrowType t, int64_t i, double v) {
  switch (t) {
    case NANOARROW_TYPE_INT8:
      ((int8_t *)data)[i] = (int8_t)v;
      break;
    case NANOARROW_TYPE_INT16:
      ((int16_t *)data)[i] = (int16_t)v;
      break;
    case NANOARROW_TYPE_INT32:
      ((int32_t *)data)[i] = (int32_t)v;
      break;
    case NANOARROW_TYPE_INT64:
      ((int64_t *)data)[i] = (int64_t)v;
      break;
    case NANOARROW_TYPE_UINT8:
      ((uint8_t *)data)[i] = (uint8_t)v;
      break;
    case NANOARROW_TYPE_UINT16:
      ((uint16_t *)data)[i] = (uint16_t)v;
      break;
    case NANOARROW_TYPE_UINT32:
      ((uint32_t *)data)[i] = (uint32_t)v;
      break;
    default:
      ((uint64_t *)data)[i] = (uint64_t)v;
      break;
  }
}

static int64_t zar_type_bytes(enum ArrowType t) {
  switch (t) {
    case NANOARROW_TYPE_INT8:
    case NANOARROW_TYPE_UINT8:
      return 1;
    case NANOARROW_TYPE_INT16:
    case NANOARROW_TYPE_UINT16:
    case NANOARROW_TYPE_HALF_FLOAT:
      return 2;
    case NANOARROW_TYPE_INT32:
    case NANOARROW_TYPE_UINT32:
    case NANOARROW_TYPE_FLOAT:
    case NANOARROW_TYPE_DATE32:
    case NANOARROW_TYPE_TIME32:
      return 4;
    default:
      return 8;
  }
}

/* Integers and doubles into any integer or floating type. `scale`
   multiplies each value first and `round` rounds it to the unit, for
   temporal types. */
static int zar_build_numeric(struct ArrowArray *array, enum ArrowType t,
                             SEXP x, R_xlen_t start, int64_t n, double scale,
                             int round_to_unit, struct zar_build *b) {
  int is_int = TYPEOF(x) == INTSXP;
  zar_is_na_fn is_na = is_int ? zar_na_int : zar_na_dbl;
  if (zar_set_validity(array, x, start, n, is_na, b) != NANOARROW_OK) {
    return EINVAL;
  }
  /* The two paths below write every byte, so only the general loop, which
     leaves null slots alone, needs a zeroed buffer. */
  int writes_all = (is_int && t == NANOARROW_TYPE_INT32) ||
                   (!is_int && t == NANOARROW_TYPE_DOUBLE && scale == 1.0);
  int64_t bytes = n * zar_type_bytes(t);
  void *data = writes_all ? zar_data_uninit(array, 1, bytes, b) : zar_data(array, 1, bytes, b);
  if (data == NULL) return zar_build_fail(b, NULL, NA_REAL);

  if (n == 0) return NANOARROW_OK;
  /* The R data pointers, taken once: INTEGER() and REAL() are calls. */
  const int *ip = is_int ? INTEGER(x) : NULL;
  const double *dp = is_int ? NULL : REAL(x);
  if (is_int && t == NANOARROW_TYPE_INT32) {
    if (array->null_count == 0) {
      memcpy(data, ip + start, (size_t)n * sizeof(int32_t));
    } else {
      /* A null slot holds zero, as the general loop leaves it. */
      int32_t *dst = (int32_t *)data;
      for (int64_t i = 0; i < n; i++) dst[i] = ip[start + i] == NA_INTEGER ? 0 : ip[start + i];
    }
    return NANOARROW_OK;
  }
  if (!is_int && t == NANOARROW_TYPE_DOUBLE && scale == 1.0) {
    const double *src = dp + start;
    double *dst = (double *)data;
    for (int64_t i = 0; i < n; i++) dst[i] = ZAR_NA_DBL(src[i]) ? 0.0 : src[i];
    return NANOARROW_OK;
  }

  for (int64_t i = 0; i < n; i++) {
    R_xlen_t k = start + (R_xlen_t)i;
    if (is_int ? ip[k] == NA_INTEGER : ZAR_NA_DBL(dp[k])) continue;
    double v = is_int ? (double)ip[k] : dp[k];
    v *= scale;
    if (t == NANOARROW_TYPE_DOUBLE) {
      ((double *)data)[i] = v;
      continue;
    }
    if (t == NANOARROW_TYPE_FLOAT) {
      float f = (float)v;
      if (!ISNAN(v) && (double)f != v) {
        ArrowErrorSet(&b->error, "row %" PRId64 " holds %.17g, which a float cannot hold exactly",
                      (int64_t)k + 1, v);
        return zar_build_fail(b, "lossy", (double)k + 1);
      }
      ((float *)data)[i] = f;
      continue;
    }
    if (round_to_unit) v = nearbyint(v);
    /* int32 and date32, the common case: a range test and one cast prove a
       whole number in range (NaN fails the comparison). Anything else goes
       through the general check below, which raises the error. */
    if (t == NANOARROW_TYPE_INT32 || t == NANOARROW_TYPE_DATE32) {
      if (v >= -2147483648.0 && v <= 2147483647.0 && (double)(int32_t)v == v) {
        ((int32_t *)data)[i] = (int32_t)v;
        continue;
      }
    }
    if (!R_FINITE(v) || v != floor(v) || !zar_int_fits(t, v)) {
      ArrowErrorSet(&b->error, "row %" PRId64 " holds %.17g, which %s cannot hold exactly",
                    (int64_t)k + 1, is_int ? (double)ip[k] : dp[k], ArrowTypeString(t));
      return zar_build_fail(b, "lossy", (double)k + 1);
    }
    zar_store_int(data, t, i, v);
  }
  return NANOARROW_OK;
}

static int zar_build_bool(struct ArrowArray *array, SEXP x, R_xlen_t start,
                          int64_t n, struct zar_build *b) {
  if (zar_set_validity(array, x, start, n, zar_na_lgl, b) != NANOARROW_OK) {
    return EINVAL;
  }
  uint8_t *data = (uint8_t *)zar_data(array, 1, (n + 7) / 8, b);
  if (data == NULL) return zar_build_fail(b, NULL, NA_REAL);
  /* Eight values to a byte without a branch: random TRUE and FALSE make a
     branch per value mispredict half the time. */
  const int *src = LOGICAL(x) + start;
  int64_t i = 0;
  for (; i + 8 <= n; i += 8) {
    uint8_t byte = 0;
    for (int k = 0; k < 8; k++) {
      byte |= (uint8_t)(((src[i + k] != 0) & (src[i + k] != NA_LOGICAL)) << k);
    }
    data[i >> 3] = byte;
  }
  for (; i < n; i++) {
    if (src[i] != NA_LOGICAL && src[i]) ArrowBitSet(data, i);
  }
  return NANOARROW_OK;
}

/* ---- strings and bytes ------------------------------------------------- */

/* The UTF-8 bytes of a string zar_char_utf8() has already accepted. */
static const char *zar_utf8_checked(SEXP s, size_t *len) {
  const char *u = Rf_translateCharUTF8(s);
  *len = u == CHAR(s) ? (size_t)LENGTH(s) : strlen(u);
  return u;
}

static int zar_build_strings(struct ArrowArray *array, enum ArrowType t,
                             SEXP x, R_xlen_t start, int64_t n,
                             struct zar_build *b) {
  int large = t == NANOARROW_TYPE_LARGE_STRING;
  if (zar_set_validity(array, x, start, n, zar_na_chr, b) != NANOARROW_OK) {
    return EINVAL;
  }
  int64_t total = 0;
  for (int64_t i = 0; i < n; i++) {
    SEXP s = STRING_ELT(x, start + (R_xlen_t)i);
    size_t len;
    if (s != NA_STRING) {
      if (zar_char_utf8(s, &len) == NULL) {
        ArrowErrorSet(&b->error, "row %" PRId64 " is not valid UTF-8",
                      (int64_t)start + i + 1);
        return zar_build_fail(b, "type", (double)start + i + 1);
      }
      total += (int64_t)len;
    }
  }
  if (!large && total > INT32_MAX) {
    ArrowErrorSet(&b->error, "the strings hold %" PRId64 " bytes, more than utf8 offsets can address", total);
    return zar_build_fail(b, "limit", NA_REAL);
  }
  void *offsets = zar_data(array, 1, (n + 1) * (large ? 8 : 4), b);
  char *data = offsets == NULL ? NULL : (char *)zar_data(array, 2, total, b);
  if (data == NULL && total > 0) return zar_build_fail(b, NULL, NA_REAL);
  if (offsets == NULL) return zar_build_fail(b, NULL, NA_REAL);
  int64_t at = 0;
  for (int64_t i = 0; i < n; i++) {
    SEXP s = STRING_ELT(x, start + (R_xlen_t)i);
    if (s != NA_STRING) {
      size_t len;
      const char *u = zar_utf8_checked(s, &len);
      if (len > 0) memcpy(data + at, u, len);
      at += (int64_t)len;
    }
    if (large) {
      ((int64_t *)offsets)[i + 1] = at;
    } else {
      ((int32_t *)offsets)[i + 1] = (int32_t)at;
    }
  }
  return NANOARROW_OK;
}

static int zar_build_blobs(struct ArrowArray *array, enum ArrowType t,
                           int32_t width, SEXP x, R_xlen_t start, int64_t n,
                           struct zar_build *b) {
  if (zar_set_validity(array, x, start, n, zar_na_list, b) != NANOARROW_OK) {
    return EINVAL;
  }
  int64_t total = 0;
  for (int64_t i = 0; i < n; i++) {
    SEXP e = VECTOR_ELT(x, start + (R_xlen_t)i);
    if (e == R_NilValue) continue;
    if (TYPEOF(e) != RAWSXP) {
      ArrowErrorSet(&b->error, "element %" PRId64 " is not a raw vector", (int64_t)i + 1);
      return zar_build_fail(b, "type", (double)start + i + 1);
    }
    if (t == NANOARROW_TYPE_FIXED_SIZE_BINARY && Rf_xlength(e) != width) {
      ArrowErrorSet(&b->error, "element %" PRId64 " has %ld bytes, not %d",
                    (int64_t)i + 1, (long)Rf_xlength(e), width);
      return zar_build_fail(b, "type", (double)start + i + 1);
    }
    total += (int64_t)Rf_xlength(e);
  }
  if (t == NANOARROW_TYPE_FIXED_SIZE_BINARY) {
    uint8_t *data = (uint8_t *)zar_data(array, 1, n * width, b);
    if (data == NULL && n * width > 0) return zar_build_fail(b, NULL, NA_REAL);
    for (int64_t i = 0; i < n; i++) {
      SEXP e = VECTOR_ELT(x, start + (R_xlen_t)i);
      if (e != R_NilValue && width > 0) {
        memcpy(data + i * width, RAW(e), (size_t)width);
      }
    }
    return NANOARROW_OK;
  }
  int large = t == NANOARROW_TYPE_LARGE_BINARY;
  if (!large && total > INT32_MAX) {
    ArrowErrorSet(&b->error, "the values hold %" PRId64 " bytes, more than binary offsets can address", total);
    return zar_build_fail(b, "limit", NA_REAL);
  }
  void *offsets = zar_data(array, 1, (n + 1) * (large ? 8 : 4), b);
  uint8_t *data = offsets == NULL ? NULL : (uint8_t *)zar_data(array, 2, total, b);
  if (offsets == NULL || (data == NULL && total > 0)) {
    return zar_build_fail(b, NULL, NA_REAL);
  }
  int64_t at = 0;
  for (int64_t i = 0; i < n; i++) {
    SEXP e = VECTOR_ELT(x, start + (R_xlen_t)i);
    if (e != R_NilValue && Rf_xlength(e) > 0) {
      memcpy(data + at, RAW(e), (size_t)Rf_xlength(e));
      at += (int64_t)Rf_xlength(e);
    }
    if (large) {
      ((int64_t *)offsets)[i + 1] = at;
    } else {
      ((int32_t *)offsets)[i + 1] = (int32_t)at;
    }
  }
  return NANOARROW_OK;
}

/* ---- the exact text forms, read back ----------------------------------- */

static int zar_has_text_target(enum ArrowType t) {
  switch (t) {
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

static int zar_text_digits(enum ArrowTimeUnit unit) {
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

/* Writes a character vector as the type its text names (section 6.3). */
static int zar_build_text(struct ArrowArray *array,
                          const struct ArrowSchemaView *sv, SEXP x,
                          R_xlen_t start, int64_t n, struct zar_build *b) {
  enum ArrowType t = sv->type;
  if (zar_set_validity(array, x, start, n, zar_na_chr, b) != NANOARROW_OK) {
    return EINVAL;
  }
  int decimal = t == NANOARROW_TYPE_DECIMAL32 || t == NANOARROW_TYPE_DECIMAL64 ||
                t == NANOARROW_TYPE_DECIMAL128 || t == NANOARROW_TYPE_DECIMAL256;
  int64_t width = decimal ? sv->decimal_bitwidth / 8 : zar_type_bytes(t);
  uint8_t *data = (uint8_t *)zar_data(array, 1, n * width, b);
  if (data == NULL && n > 0) return zar_build_fail(b, NULL, NA_REAL);

  for (int64_t i = 0; i < n; i++) {
    R_xlen_t k = start + (R_xlen_t)i;
    SEXP chr = STRING_ELT(x, k);
    if (chr == NA_STRING) continue;
    size_t text_len;
    const char *text = zar_char_utf8(chr, &text_len);
    if (text == NULL) {
      ArrowErrorSet(&b->error, "row %" PRId64 " is not valid UTF-8", (int64_t)k + 1);
      return zar_build_fail(b, "type", (double)k + 1);
    }
    int code;
    int64_t v = 0;
    if (decimal) {
      struct ArrowDecimal dec;
      ArrowDecimalInit(&dec, sv->decimal_bitwidth, sv->decimal_precision,
                       sv->decimal_scale);
      code = zar_parse_decimal(text, &dec);
      if (code == NANOARROW_OK) {
        uint8_t bytes[32];
        ArrowDecimalGetBytes(&dec, bytes);
        memcpy(data + i * width, bytes, (size_t)width);
      }
    } else {
      switch (t) {
        case NANOARROW_TYPE_UINT8:
        case NANOARROW_TYPE_UINT16:
        case NANOARROW_TYPE_UINT32:
        case NANOARROW_TYPE_UINT64: {
          uint64_t u;
          code = zar_parse_uint64(text, &u);
          if (code == NANOARROW_OK &&
              !zar_int_fits(t, (double)u) && t != NANOARROW_TYPE_UINT64) {
            code = ERANGE;
          }
          if (code == NANOARROW_OK) {
            if (t == NANOARROW_TYPE_UINT64) {
              ((uint64_t *)data)[i] = u;
            } else {
              zar_store_int(data, t, i, (double)u);
            }
          }
          break;
        }
        case NANOARROW_TYPE_DATE32:
          code = zar_parse_date(text, &v);
          if (code == NANOARROW_OK && (v < INT32_MIN || v > INT32_MAX)) {
            code = ERANGE;
          }
          if (code == NANOARROW_OK) ((int32_t *)data)[i] = (int32_t)v;
          break;
        case NANOARROW_TYPE_DATE64:
          code = zar_parse_instant(text, 3, 1, &v);
          if (code == NANOARROW_OK) ((int64_t *)data)[i] = v;
          break;
        case NANOARROW_TYPE_TIMESTAMP:
          code = zar_parse_instant(
              text, zar_text_digits(sv->time_unit),
              sv->timezone != NULL && sv->timezone[0] != '\0', &v);
          if (code == NANOARROW_OK) ((int64_t *)data)[i] = v;
          break;
        case NANOARROW_TYPE_TIME32:
        case NANOARROW_TYPE_TIME64:
          code = zar_parse_time(text, zar_text_digits(sv->time_unit), &v);
          if (code == NANOARROW_OK && t == NANOARROW_TYPE_TIME32) {
            if (v < INT32_MIN || v > INT32_MAX) {
              code = ERANGE;
            } else {
              ((int32_t *)data)[i] = (int32_t)v;
            }
          } else if (code == NANOARROW_OK) {
            ((int64_t *)data)[i] = v;
          }
          break;
        default: /* signed integers and durations */
          code = zar_parse_int64(text, &v);
          if (code == NANOARROW_OK && t != NANOARROW_TYPE_INT64 &&
              t != NANOARROW_TYPE_DURATION && !zar_int_fits(t, (double)v)) {
            code = ERANGE;
          }
          if (code == NANOARROW_OK) {
            if (t == NANOARROW_TYPE_INT64 || t == NANOARROW_TYPE_DURATION) {
              ((int64_t *)data)[i] = v;
            } else {
              zar_store_int(data, t, i, (double)v);
            }
          }
          break;
      }
    }
    if (code != NANOARROW_OK) {
      ArrowErrorSet(&b->error, "row %" PRId64 " holds \"%s\", which is not %s %s",
                    (int64_t)k + 1, text, code == ERANGE ? "exactly a" : "the text of a",
                    ArrowTypeString(t));
      return zar_build_fail(b, code == ERANGE ? "lossy" : "type", (double)k + 1);
    }
  }
  return NANOARROW_OK;
}

/* ---- nested, dictionaries, prebuilt arrays ----------------------------- */

static int zar_build_array(struct ArrowArray *array,
                           const struct ArrowSchema *schema, SEXP x,
                           R_xlen_t start, int64_t n, struct zar_build *b);

static SEXP zar_prep_get(SEXP prep, const char *name) {
  SEXP names = Rf_getAttrib(prep, R_NamesSymbol);
  for (R_xlen_t i = 0; i < Rf_xlength(prep); i++) {
    if (strcmp(CHAR(STRING_ELT(names, i)), name) == 0) return VECTOR_ELT(prep, i);
  }
  return R_NilValue;
}

/* The number of rows an R object holds as a list column's values: a data
   frame's rows, a prepared list's elements, a vector's length. -1 when it
   cannot be told, as for a registered column. */
static int64_t zar_value_rows(SEXP x) {
  if (x == R_NilValue) return 0;
  if (Rf_inherits(x, "data.frame")) {
    SEXP rn = Rf_getAttrib(x, R_RowNamesSymbol);
    return (int64_t)Rf_xlength(rn);
  }
  if (Rf_inherits(x, "zar_list_prep")) {
    SEXP offsets = zar_prep_get(x, "offsets");
    return TYPEOF(offsets) == REALSXP ? (int64_t)Rf_xlength(offsets) - 1 : -1;
  }
  if (Rf_inherits(x, "zar_registered")) return -1;
  return (int64_t)Rf_xlength(x);
}

/* A list column R has flattened: list(offsets, null, values), offsets the
   cumulative element lengths (n + 1 doubles), null a logical per element,
   values every element's values concatenated (section 6.4). */
static int zar_build_list(struct ArrowArray *array,
                          const struct ArrowSchema *schema,
                          const struct ArrowSchemaView *sv, SEXP prep,
                          R_xlen_t start, int64_t n, struct zar_build *b) {
  SEXP offsets = zar_prep_get(prep, "offsets");
  SEXP nulls = zar_prep_get(prep, "null");
  SEXP values = zar_prep_get(prep, "values");
  if (TYPEOF(offsets) != REALSXP || TYPEOF(nulls) != LGLSXP ||
      Rf_xlength(offsets) < start + n + 1 || Rf_xlength(nulls) < start + n) {
    ArrowErrorSet(&b->error, "a malformed list column");
    return zar_build_fail(b, NULL, NA_REAL);
  }
  const double *off = REAL(offsets);
  int64_t rows = zar_value_rows(values);
  double last = off[Rf_xlength(offsets) - 1];
  if (rows >= 0 && (double)rows != last) {
    ArrowErrorSet(&b->error, "the list's values hold %" PRId64 " rows where its offsets end at %.0f",
                  rows, last);
    return zar_build_fail(b, "type", NA_REAL);
  }
  if (zar_set_validity(array, nulls, start, n, zar_na_lgl_true, b) != NANOARROW_OK) {
    return EINVAL;
  }
  int64_t first = (int64_t)off[start];
  int64_t total = (int64_t)off[start + n] - first;
  enum ArrowType t = sv->type;
  if (t == NANOARROW_TYPE_FIXED_SIZE_LIST) {
    for (int64_t i = 0; i < n; i++) {
      if ((int64_t)(off[start + i + 1] - off[start + i]) != sv->fixed_size) {
        ArrowErrorSet(&b->error, "row %" PRId64 " has %" PRId64 " values, not %d",
                      (int64_t)start + i + 1,
                      (int64_t)(off[start + i + 1] - off[start + i]), sv->fixed_size);
        return zar_build_fail(b, "type", (double)start + i + 1);
      }
    }
  } else {
    int large = t == NANOARROW_TYPE_LARGE_LIST;
    if (!large && total > INT32_MAX) {
      ArrowErrorSet(&b->error, "the lists hold %" PRId64 " values, more than list offsets address", total);
      return zar_build_fail(b, "limit", NA_REAL);
    }
    void *dst = zar_data(array, 1, (n + 1) * (large ? 8 : 4), b);
    if (dst == NULL) return zar_build_fail(b, NULL, NA_REAL);
    for (int64_t i = 0; i <= n; i++) {
      int64_t v = (int64_t)off[start + i] - first;
      if (large) {
        ((int64_t *)dst)[i] = v;
      } else {
        ((int32_t *)dst)[i] = (int32_t)v;
      }
    }
  }
  return zar_build_array(array->children[0], schema->children[0], values,
                         (R_xlen_t)first, total, b);
}

/* A factor as dictionary<index, utf8>: the codes as indices, the levels as
   the dictionary (section 6.5). */
static int zar_build_dictionary(struct ArrowArray *array,
                                const struct ArrowSchema *schema, SEXP x,
                                R_xlen_t start, int64_t n, struct zar_build *b) {
  struct ArrowSchemaView index_view;
  struct ArrowSchema index_schema = *schema;
  index_schema.dictionary = NULL;
  index_schema.flags &= ~ARROW_FLAG_DICTIONARY_ORDERED;
  if (ArrowSchemaViewInit(&index_view, &index_schema, &b->error) != NANOARROW_OK) {
    return zar_build_fail(b, "format", NA_REAL);
  }
  SEXP codes = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)n));
  const int *src = INTEGER(x) + start;
  int *dst = INTEGER(codes);
  for (int64_t i = 0; i < n; i++) dst[i] = src[i] == NA_INTEGER ? NA_INTEGER : src[i] - 1;
  int status = zar_build_numeric(array, index_view.type, codes, 0, n, 1.0, 0, b);
  UNPROTECT(1);
  if (status != NANOARROW_OK) return status;
  SEXP levels = Rf_getAttrib(x, R_LevelsSymbol);
  if (TYPEOF(levels) != STRSXP) {
    ArrowErrorSet(&b->error, "a factor without character levels");
    return zar_build_fail(b, "type", NA_REAL);
  }
  return zar_build_array(array->dictionary, schema->dictionary, levels, 0,
                         (int64_t)Rf_xlength(levels), b);
}

/* An array a registered `from` handler built: moved into its slot after
   its schema is checked against the slot's. */
static int zar_build_prebuilt(struct ArrowArray *array,
                              const struct ArrowSchema *schema, SEXP x,
                              int64_t n, struct zar_build *b) {
  struct ArrowArray *src = zar_array_from_xptr(x, &b->error);
  if (src == NULL) return zar_build_fail(b, "handle", NA_REAL);
  SEXP tag = zar_array_schema_xptr(x, &b->error);
  if (tag == NULL) return zar_build_fail(b, "handle", NA_REAL);
  struct ArrowSchema *src_schema = zar_schema_from_xptr(tag, &b->error);
  if (strcmp(src_schema->format, schema->format) != 0 ||
      src_schema->n_children != schema->n_children) {
    ArrowErrorSet(&b->error, "a registered handler built %s where the schema says %s",
                  src_schema->format, schema->format);
    return zar_build_fail(b, "registry", NA_REAL);
  }
  if (src->length != n) {
    ArrowErrorSet(&b->error, "a registered handler built %" PRId64 " values, not %" PRId64,
                  src->length, n);
    return zar_build_fail(b, "registry", NA_REAL);
  }
  if (b->n_prebuilt >= ZAR_MAX_PREBUILT) {
    ArrowErrorSet(&b->error, "more than %d registered columns", ZAR_MAX_PREBUILT);
    return zar_build_fail(b, "limit", NA_REAL);
  }
  /* A placeholder of the right length until the swap. */
  array->length = n;
  array->null_count = 0;
  b->slots[b->n_prebuilt] = array;
  b->sources[b->n_prebuilt] = x;
  b->n_prebuilt++;
  return NANOARROW_OK;
}

/* Swaps the prebuilt arrays into their slots, consuming their handles. */
static void zar_swap_prebuilt(struct zar_build *b) {
  for (int k = 0; k < b->n_prebuilt; k++) {
    struct ArrowArray *slot = b->slots[k];
    struct ArrowArray *src = (struct ArrowArray *)R_ExternalPtrAddr(b->sources[k]);
    if (slot->release != NULL) slot->release(slot);
    ArrowArrayMove(src, slot);
  }
}

/* ---- dispatch ---------------------------------------------------------- */

static double zar_difftime_seconds(SEXP x) {
  SEXP units = Rf_getAttrib(x, Rf_install("units"));
  if (TYPEOF(units) != STRSXP || Rf_xlength(units) != 1) return 1.0;
  const char *u = CHAR(STRING_ELT(units, 0));
  if (strcmp(u, "mins") == 0) return 60.0;
  if (strcmp(u, "hours") == 0) return 3600.0;
  if (strcmp(u, "days") == 0) return 86400.0;
  if (strcmp(u, "weeks") == 0) return 604800.0;
  return 1.0;
}

static double zar_unit_per_second(enum ArrowTimeUnit unit) {
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

static int zar_build_array(struct ArrowArray *array,
                           const struct ArrowSchema *schema, SEXP x,
                           R_xlen_t start, int64_t n, struct zar_build *b);

static int zar_build_struct(struct ArrowArray *array,
                            const struct ArrowSchema *schema, SEXP x,
                            R_xlen_t start, int64_t n, struct zar_build *b) {
  if (!Rf_inherits(x, "data.frame")) {
    ArrowErrorSet(&b->error, "a struct column needs a data frame");
    return zar_build_fail(b, "type", NA_REAL);
  }
  if (Rf_xlength(x) != schema->n_children) {
    ArrowErrorSet(&b->error, "the data frame has %ld columns, the schema %ld",
                  (long)Rf_xlength(x), (long)schema->n_children);
    return zar_build_fail(b, "type", NA_REAL);
  }
  for (int64_t c = 0; c < schema->n_children; c++) {
    int code = zar_build_array(array->children[c], schema->children[c],
                               VECTOR_ELT(x, (R_xlen_t)c), start, n, b);
    if (code != NANOARROW_OK) {
      char inner[sizeof(b->error.message)];
      memcpy(inner, b->error.message, sizeof(inner));
      ArrowErrorSet(&b->error, "column '%s': %s",
                    schema->children[c]->name == NULL ? ""
                                                      : schema->children[c]->name,
                    inner);
      return code;
    }
  }
  return NANOARROW_OK;
}

static int zar_build_array(struct ArrowArray *array,
                           const struct ArrowSchema *schema, SEXP x,
                           R_xlen_t start, int64_t n, struct zar_build *b) {
  struct ArrowSchemaView sv;
  if (ArrowSchemaViewInit(&sv, schema, &b->error) != NANOARROW_OK) {
    return zar_build_fail(b, "format", NA_REAL);
  }
  array->length = n;
  array->null_count = 0;
  enum ArrowType t = sv.type;
  int type = TYPEOF(x);

  if (TYPEOF(x) == EXTPTRSXP && Rf_inherits(x, "nanoarrow_array")) {
    return zar_build_prebuilt(array, schema, x, n, b);
  }
  if (t == NANOARROW_TYPE_STRUCT) {
    return zar_build_struct(array, schema, x, start, n, b);
  }
  if (Rf_inherits(x, "zar_list_prep")) {
    if (t == NANOARROW_TYPE_LIST || t == NANOARROW_TYPE_LARGE_LIST ||
        t == NANOARROW_TYPE_FIXED_SIZE_LIST) {
      return zar_build_list(array, schema, &sv, x, start, n, b);
    }
    goto unsupported;
  }
  if (Rf_isFactor(x)) {
    if (Rf_xlength(x) < start + n) goto unsupported;
    if (t == NANOARROW_TYPE_DICTIONARY) {
      return zar_build_dictionary(array, schema, x, start, n, b);
    }
    if (t == NANOARROW_TYPE_STRING || t == NANOARROW_TYPE_LARGE_STRING) {
      /* dictionary = FALSE: the factor's labels as strings. */
      SEXP levels = Rf_getAttrib(x, R_LevelsSymbol);
      SEXP labels = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)n));
      const int *codes = INTEGER(x) + start;
      for (int64_t i = 0; i < n; i++) {
        int code = codes[i];
        SET_STRING_ELT(labels, (R_xlen_t)i,
                       code == NA_INTEGER ? NA_STRING : STRING_ELT(levels, code - 1));
      }
      int status = zar_build_strings(array, t, labels, 0, n, b);
      UNPROTECT(1);
      return status;
    }
    goto unsupported;
  }
  if (Rf_inherits(x, "data.frame")) {
    goto unsupported;
  }
  if (t == NANOARROW_TYPE_NA) {
    if (x == R_NilValue || (type == LGLSXP && Rf_xlength(x) >= start + n)) {
      array->null_count = n;
      return NANOARROW_OK;
    }
    goto unsupported;
  }
  if (Rf_xlength(x) < start + n) {
    ArrowErrorSet(&b->error, "the vector is shorter than its rows");
    return zar_build_fail(b, "type", NA_REAL);
  }
  if (type == STRSXP && zar_has_text_target(t)) {
    return zar_build_text(array, &sv, x, start, n, b);
  }

  switch (t) {
    case NANOARROW_TYPE_BOOL:
      if (type == LGLSXP) return zar_build_bool(array, x, start, n, b);
      break;
    case NANOARROW_TYPE_INT8:
    case NANOARROW_TYPE_INT16:
    case NANOARROW_TYPE_INT32:
    case NANOARROW_TYPE_INT64:
    case NANOARROW_TYPE_UINT8:
    case NANOARROW_TYPE_UINT16:
    case NANOARROW_TYPE_UINT32:
    case NANOARROW_TYPE_UINT64:
    case NANOARROW_TYPE_FLOAT:
    case NANOARROW_TYPE_DOUBLE:
      if ((type == INTSXP || type == REALSXP) && !Rf_isObject(x)) {
        return zar_build_numeric(array, t, x, start, n, 1.0, 0, b);
      }
      if (type == LGLSXP && t == NANOARROW_TYPE_INT8) {
        /* arrow.bool8: a logical as 0 and 1 in int8 storage. */
        SEXP ints = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)n));
        const int *src = LOGICAL(x) + start;
        int *dst = INTEGER(ints);
        for (int64_t i = 0; i < n; i++) dst[i] = src[i] == NA_LOGICAL ? NA_INTEGER : (src[i] != 0);
        int status = zar_build_numeric(array, t, ints, 0, n, 1.0, 0, b);
        UNPROTECT(1);
        return status;
      }
      break;
    case NANOARROW_TYPE_DATE32:
    case NANOARROW_TYPE_DATE64:
      if ((type == REALSXP || type == INTSXP) && Rf_inherits(x, "Date")) {
        double scale = t == NANOARROW_TYPE_DATE64 ? 86400000.0 : 1.0;
        return zar_build_numeric(array, t == NANOARROW_TYPE_DATE32
                                            ? NANOARROW_TYPE_INT32
                                            : NANOARROW_TYPE_INT64,
                                 x, start, n, scale, 0, b);
      }
      break;
    case NANOARROW_TYPE_TIMESTAMP:
      if ((type == REALSXP || type == INTSXP) && Rf_inherits(x, "POSIXct")) {
        return zar_build_numeric(array, NANOARROW_TYPE_INT64, x, start, n,
                                 zar_unit_per_second(sv.time_unit), 1, b);
      }
      break;
    case NANOARROW_TYPE_DURATION:
      if ((type == REALSXP || type == INTSXP) && Rf_inherits(x, "difftime")) {
        return zar_build_numeric(
            array, NANOARROW_TYPE_INT64, x, start, n,
            zar_difftime_seconds(x) * zar_unit_per_second(sv.time_unit), 1, b);
      }
      break;
    case NANOARROW_TYPE_STRING:
    case NANOARROW_TYPE_LARGE_STRING:
      if (type == STRSXP) return zar_build_strings(array, t, x, start, n, b);
      break;
    case NANOARROW_TYPE_BINARY:
    case NANOARROW_TYPE_LARGE_BINARY:
    case NANOARROW_TYPE_FIXED_SIZE_BINARY:
      if (type == VECSXP && !Rf_isObject(x)) {
        return zar_build_blobs(array, t, sv.fixed_size, x, start, n, b);
      }
      break;
    default:
      break;
  }

unsupported:
  ArrowErrorSet(&b->error, "an R object of type %s cannot be written as %s",
                Rf_type2char((SEXPTYPE)type), ArrowTypeString(t));
  return zar_build_fail(b, "type", NA_REAL);
}

static int64_t zar_utf8_bytes(SEXP x) {
  int64_t total = 0;
  for (R_xlen_t i = 0; i < Rf_xlength(x); i++) {
    SEXP s = STRING_ELT(x, i);
    size_t len;
    if (s != NA_STRING && zar_char_utf8(s, &len) != NULL) {
      total += (int64_t)len;
    }
  }
  return total;
}

/* Builds rows [start, start + n) of `x` as an array of `schema_xptr`.
   `utf8_limit` is NA when the schema was given; otherwise a character
   vector holding more bytes than it is written as large_utf8 (section
   6.2). R passes 2^31 - 1, the most utf8's offsets address. */
SEXP zar_c_from_r(SEXP x, SEXP schema_xptr, SEXP r_start, SEXP r_n,
                  SEXP utf8_limit) {
  struct zar_build b;
  b.error.message[0] = '\0';
  b.kind = NULL;
  b.row = NA_REAL;
  b.n_prebuilt = 0;
  R_xlen_t start = (R_xlen_t)Rf_asReal(r_start);
  int64_t n = (int64_t)Rf_asReal(r_n);

  SEXP schema_copy = PROTECT(zar_schema_copy_of(schema_xptr));
  if (Rf_inherits(schema_copy, "zar_failure")) {
    UNPROTECT(1);
    return schema_copy;
  }
  struct ArrowSchema *schema =
      (struct ArrowSchema *)R_ExternalPtrAddr(schema_copy);
  double limit = Rf_asReal(utf8_limit);
  if (!ISNAN(limit) && TYPEOF(x) == STRSXP &&
      strcmp(schema->format, "u") == 0 && (double)zar_utf8_bytes(x) > limit) {
    if (ArrowSchemaSetFormat(schema, "U") != NANOARROW_OK) {
      UNPROTECT(1);
      return zar_failure(NULL, "cannot allocate a format string");
    }
  }

  SEXP out = PROTECT(zar_array_owning_xptr(schema_copy));
  struct ArrowArray *array = (struct ArrowArray *)R_ExternalPtrAddr(out);
  int code = ArrowArrayInitFromSchema(array, schema, &b.error);
  if (code != NANOARROW_OK) b.kind = "format";
  if (code == NANOARROW_OK) code = zar_build_array(array, schema, x, start, n, &b);
  if (code == NANOARROW_OK && b.n_prebuilt == 0) {
    code = ArrowArrayFinishBuildingDefault(array, &b.error);
    if (code != NANOARROW_OK) b.kind = "format";
  } else if (code == NANOARROW_OK) {
    code = ArrowArrayFinishBuilding(array, NANOARROW_VALIDATION_LEVEL_NONE, &b.error);
    if (code == NANOARROW_OK) {
      zar_swap_prebuilt(&b);
      struct ArrowArrayView view;
      code = ArrowArrayViewInitFromSchema(&view, schema, &b.error);
      if (code == NANOARROW_OK) code = ArrowArrayViewSetArray(&view, array, &b.error);
      ArrowArrayViewReset(&view);
    }
    if (code != NANOARROW_OK) b.kind = "format";
  }
  UNPROTECT(2);
  if (code != NANOARROW_OK) {
    if (b.kind != NULL && strcmp(b.kind, "lossy") == 0) {
      SEXP fail = PROTECT(zar_failure_from_error(b.kind, &b.error));
      SEXP row = PROTECT(Rf_ScalarReal(b.row));
      SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));
      SET_STRING_ELT(names, 0, Rf_mkChar("kind"));
      SET_STRING_ELT(names, 1, Rf_mkChar("message"));
      SET_STRING_ELT(names, 2, Rf_mkChar("row"));
      SEXP full = PROTECT(Rf_allocVector(VECSXP, 3));
      SET_VECTOR_ELT(full, 0, VECTOR_ELT(fail, 0));
      SET_VECTOR_ELT(full, 1, VECTOR_ELT(fail, 1));
      SET_VECTOR_ELT(full, 2, row);
      Rf_setAttrib(full, R_NamesSymbol, names);
      Rf_setAttrib(full, R_ClassSymbol, Rf_getAttrib(fail, R_ClassSymbol));
      UNPROTECT(4);
      return full;
    }
    return zar_failure_from_error(b.kind, &b.error);
  }
  return out;
}
