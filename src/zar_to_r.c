/* Arrow to R (design sections 6.2 to 6.6, 6.9). Each column gets a plan, a
   tree that mirrors its schema and decides every node's R form from its
   type and the lossy policy. A value scan settles the nodes whose
   exactness depends on their values. Then each node is allocated once and
   filled from every batch. Nothing here calls back into R code: only R's
   allocators and setters. */
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

/* An explicit `to` target for a top-level column, as R numbers it. */
enum zar_to {
  ZAR_TO_NONE = 0,
  ZAR_TO_CHARACTER = 1,
  ZAR_TO_DOUBLE = 2,
  ZAR_TO_INTEGER = 3,
  ZAR_TO_MATRIX = 4,
  ZAR_TO_SKIP = 9 /* a registered handler converts it in R */
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
  ZAR_T_TEXT,     /* the exact canonical text, with arrow_type */
  ZAR_T_STRUCT,   /* data frame */
  ZAR_T_LIST,     /* list column, from list, large_list and the views */
  ZAR_T_FSL,      /* list column from fixed_size_list */
  ZAR_T_MATRIX,   /* matrix from fixed_size_list */
  ZAR_T_MAP,      /* list column of key/value data frames */
  ZAR_T_FACTOR,   /* factor from a dictionary of strings */
  ZAR_T_DECODE,   /* a dictionary decoded through its values' plan */
  ZAR_T_REE,      /* run-end encoded, decoded through its values' plan */
  ZAR_T_SKIP      /* left for R */
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

struct zar_plan {
  struct ArrowSchemaView sv;
  const struct ArrowSchema *schema;
  enum zar_target target;
  enum zar_target lossy_target; /* the lossy form under warn or allow */
  enum zar_scan scan;
  int lossy_by_schema;
  int never;  /* no R form at all: intervals, unions */
  int warned; /* lossy under warn: R emits the warning */
  int bool8;  /* arrow.bool8: int8 storage read as logical */
  double per_second;
  int64_t n_children;
  struct zar_plan *children; /* fields; the item of a list; REE values */
  struct zar_plan *dict;     /* a dictionary's values */
};

/* ---- scratch: the views, owned by an external pointer ------------------ */

/* The array views live in malloc()ed memory owned by an external pointer
   whose finalizer resets them, so an R allocation that longjmps during
   the fill cannot leak them. Everything else is R_alloc()ed. */
struct zar_scratch {
  int64_t n;
  struct ArrowArrayView *views;
};

static void zar_scratch_free(struct zar_scratch *s) {
  if (s->views != NULL) {
    for (int64_t i = 0; i < s->n; i++) ArrowArrayViewReset(&s->views[i]);
    free(s->views);
    s->views = NULL;
  }
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

/* A failure found below the top level: kind, message, and where. It also
   carries the two build options zar_build() reads at every level. */
struct zar_err {
  struct ArrowError error;
  const char *kind;
  int64_t row; /* 0-based top-level row, or -1 */
  const char *format;
  int copy;    /* FALSE: string columns may be deferred (zar_altrep.c) */
  SEXP arrays; /* the batches' array handles, which deferred strings keep */
};

static int zar_fail(struct zar_err *e, const char *kind, int64_t row,
                    const char *format) {
  e->kind = kind;
  e->row = row;
  e->format = format;
  return EINVAL;
}

/* ---- slices ------------------------------------------------------------ */

/* A run of elements of one node in one batch. Element i is view element
   map[i] when there is a map (a dictionary's indices, a run-end
   encoding's runs; -1 is null), else start + i. `up` is the enclosing
   struct, whose null rows make every child NA (section 6.9). */
struct zar_slice {
  const struct ArrowArrayView *view;
  int64_t start;
  int64_t length;
  const int64_t *map;
  const struct zar_slice *up;
};

static inline int64_t zar_j(const struct zar_slice *s, int64_t i) {
  return s->map != NULL ? s->map[i] : s->start + i;
}

static int zar_is_null(const struct zar_slice *s, int64_t i) {
  if (s->up != NULL && zar_is_null(s->up, i)) return 1;
  int64_t j = zar_j(s, i);
  return j < 0 || ArrowArrayViewIsNull(s->view, j);
}

/* True when no element can be null and none is mapped: the fast paths. */
static int zar_is_plain(const struct zar_slice *s) {
  for (; s != NULL; s = s->up) {
    if (s->map != NULL || s->view->null_count != 0) return 0;
  }
  return 1;
}

/* The child slice of field k of a struct slice. */
static struct zar_slice zar_field_slice(const struct zar_slice *s, int64_t k) {
  struct zar_slice out = {s->view->children[k], 0, s->length, NULL, s};
  if (s->map == NULL) {
    out.start = s->view->offset + s->start;
  } else {
    int64_t *map = (int64_t *)R_alloc((size_t)(s->length > 0 ? s->length : 1),
                                      sizeof(int64_t));
    for (int64_t i = 0; i < s->length; i++) {
      map[i] = s->map[i] < 0 ? -1 : s->view->offset + s->map[i];
    }
    out.map = map;
  }
  return out;
}

/* The [begin, end) range of child elements under list-like element j. */
static void zar_list_range(const struct ArrowArrayView *v, int64_t j,
                           int64_t fixed, int64_t *begin, int64_t *end) {
  int64_t k = v->offset + j;
  switch (v->storage_type) {
    case NANOARROW_TYPE_FIXED_SIZE_LIST:
      *begin = k * fixed;
      *end = *begin + fixed;
      break;
    case NANOARROW_TYPE_LIST_VIEW:
      *begin = v->buffer_views[1].data.as_int32[k];
      *end = *begin + v->buffer_views[2].data.as_int32[k];
      break;
    case NANOARROW_TYPE_LARGE_LIST_VIEW:
      *begin = v->buffer_views[1].data.as_int64[k];
      *end = *begin + v->buffer_views[2].data.as_int64[k];
      break;
    default:
      *begin = ArrowArrayViewListChildOffset(v, k);
      *end = ArrowArrayViewListChildOffset(v, k + 1);
      break;
  }
}

/* A slice through a dictionary: element i of `s` is the dictionary value
   its index names. */
static struct zar_slice zar_dictionary_slice(const struct zar_slice *s) {
  int64_t *map =
      (int64_t *)R_alloc((size_t)(s->length > 0 ? s->length : 1), sizeof(int64_t));
  for (int64_t i = 0; i < s->length; i++) {
    int64_t j = zar_j(s, i);
    map[i] = (j < 0 || ArrowArrayViewIsNull(s->view, j))
                 ? -1
                 : ArrowArrayViewGetIntUnsafe(s->view, j);
  }
  struct zar_slice out = {s->view->dictionary, 0, s->length, map, s->up};
  return out;
}

/* A slice through a run-end encoding: element i is the value of the run
   that covers it. */
static struct zar_slice zar_ree_slice(const struct zar_slice *s) {
  const struct ArrowArrayView *ends = s->view->children[0];
  int64_t *map =
      (int64_t *)R_alloc((size_t)(s->length > 0 ? s->length : 1), sizeof(int64_t));
  for (int64_t i = 0; i < s->length; i++) {
    int64_t j = zar_j(s, i);
    if (j < 0) {
      map[i] = -1;
      continue;
    }
    int64_t p = s->view->offset + j;
    int64_t lo = 0, hi = ends->length;
    while (lo < hi) {
      int64_t mid = lo + (hi - lo) / 2;
      if (ArrowArrayViewGetIntUnsafe(ends, mid) > p) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    map[i] = lo < ends->length ? lo : -1;
  }
  struct zar_slice out = {s->view->children[1], 0, s->length, map, s->up};
  return out;
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

static int zar_is_string_type(enum ArrowType t) {
  return t == NANOARROW_TYPE_STRING || t == NANOARROW_TYPE_LARGE_STRING ||
         t == NANOARROW_TYPE_STRING_VIEW;
}

static int zar_extension_is(const struct zar_plan *p, const char *name) {
  size_t n = strlen(name);
  return p->sv.extension_name.size_bytes == (int64_t)n &&
         memcmp(p->sv.extension_name.data, name, n) == 0;
}

static int zar_plan_init(struct zar_plan *p, const struct ArrowSchema *schema,
                         int depth, int max_depth, struct zar_err *e);

static int zar_plan_children(struct zar_plan *p, int64_t n,
                             struct ArrowSchema **schemas, int depth,
                             int max_depth, struct zar_err *e) {
  p->n_children = n;
  p->children =
      (struct zar_plan *)R_alloc((size_t)(n > 0 ? n : 1), sizeof(struct zar_plan));
  memset(p->children, 0, (size_t)(n > 0 ? n : 1) * sizeof(struct zar_plan));
  for (int64_t k = 0; k < n; k++) {
    int code = zar_plan_init(&p->children[k], schemas[k], depth + 1, max_depth, e);
    if (code != NANOARROW_OK) return code;
  }
  return NANOARROW_OK;
}

/* Fills a plan from its schema. Returns 0, or EINVAL with `e` set. */
static int zar_plan_init(struct zar_plan *p, const struct ArrowSchema *schema,
                         int depth, int max_depth, struct zar_err *e) {
  memset(p, 0, sizeof(*p));
  p->schema = schema;
  p->per_second = 1.0;
  if (depth > max_depth) {
    ArrowErrorSet(&e->error, "the schema nests deeper than max_depth (%d)",
                  max_depth);
    return zar_fail(e, "limit", -1, schema->format);
  }
  if (ArrowSchemaViewInit(&p->sv, schema, &e->error) != NANOARROW_OK) {
    return zar_fail(e, "format", -1, schema->format);
  }

  if (zar_extension_is(p, "arrow.bool8") && p->sv.type == NANOARROW_TYPE_INT8) {
    p->bool8 = 1;
    p->target = ZAR_T_LGL;
    return NANOARROW_OK;
  }

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
    case NANOARROW_TYPE_STRUCT:
      p->target = ZAR_T_STRUCT;
      return zar_plan_children(p, schema->n_children, schema->children, depth,
                               max_depth, e);
    case NANOARROW_TYPE_LIST:
    case NANOARROW_TYPE_LARGE_LIST:
    case NANOARROW_TYPE_LIST_VIEW:
    case NANOARROW_TYPE_LARGE_LIST_VIEW:
      p->target = ZAR_T_LIST;
      return zar_plan_children(p, 1, schema->children, depth, max_depth, e);
    case NANOARROW_TYPE_FIXED_SIZE_LIST:
      p->target = ZAR_T_FSL;
      return zar_plan_children(p, 1, schema->children, depth, max_depth, e);
    case NANOARROW_TYPE_MAP:
      p->target = ZAR_T_MAP;
      return zar_plan_children(p, 1, schema->children, depth, max_depth, e);
    case NANOARROW_TYPE_RUN_END_ENCODED:
      p->target = ZAR_T_REE;
      return zar_plan_children(p, 1, schema->children + 1, depth, max_depth, e);
    case NANOARROW_TYPE_DICTIONARY: {
      p->dict = (struct zar_plan *)R_alloc(1, sizeof(struct zar_plan));
      int code = zar_plan_init(p->dict, schema->dictionary, depth + 1, max_depth, e);
      if (code != NANOARROW_OK) return code;
      p->target = zar_is_string_type(p->dict->sv.type) ? ZAR_T_FACTOR : ZAR_T_DECODE;
      break;
    }
    default:
      ArrowErrorSet(&e->error, "converting %s columns is not supported",
                    ArrowTypeString(p->sv.type));
      return zar_fail(e, "type", -1, schema->format);
  }
  return NANOARROW_OK;
}

/* Applies an explicit `to` target to a top-level plan. */
static int zar_plan_to(struct zar_plan *p, int to, struct zar_err *e) {
  enum ArrowType t = p->sv.type;
  switch (to) {
    case ZAR_TO_NONE:
      return NANOARROW_OK;
    case ZAR_TO_SKIP:
      p->target = ZAR_T_SKIP;
      p->scan = ZAR_SCAN_NONE;
      p->lossy_by_schema = 0;
      p->never = 0;
      return NANOARROW_OK;
    case ZAR_TO_CHARACTER:
      if (p->target == ZAR_T_CHR) return NANOARROW_OK;
      if (!zar_has_text_form(t) || p->bool8) break;
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
    case ZAR_TO_MATRIX:
      if (p->target == ZAR_T_FSL) {
        enum zar_target item = p->children[0].target;
        if (item == ZAR_T_LGL || item == ZAR_T_INT || item == ZAR_T_DBL ||
            item == ZAR_T_CHR) {
          p->target = ZAR_T_MATRIX;
          return NANOARROW_OK;
        }
      }
      break;
    default:
      break;
  }
  ArrowErrorSet(&e->error, "the requested R type cannot hold a %s column",
                ArrowTypeString(t));
  return zar_fail(e, "type", -1, p->schema->format);
}

/* ---- the value scan ---------------------------------------------------- */

/* Returns the first offending element of the slice, or -1. */
static int64_t zar_scan_slice(const struct zar_plan *p,
                              const struct zar_slice *s) {
  for (int64_t i = 0; i < s->length; i++) {
    if (zar_is_null(s, i)) continue;
    int64_t j = zar_j(s, i);
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
  int64_t j = zar_j(s, i);
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

/* Settles every node's target under the policy. `slices` are this node's
   slices, one per batch; `top` is whether their rows are top-level rows,
   so a lossy value can be reported by row. Sets *warned when a node went
   lossy under warn. */
static int zar_resolve(struct zar_plan *p, struct zar_slice *slices,
                       int64_t n_slices, int lossy, int top, int *warned,
                       struct zar_err *e) {
  switch (p->target) {
    case ZAR_T_SKIP:
      return NANOARROW_OK;
    case ZAR_T_STRUCT:
    case ZAR_T_MAP:
    case ZAR_T_LIST:
    case ZAR_T_FSL:
    case ZAR_T_MATRIX:
    case ZAR_T_REE:
    case ZAR_T_FACTOR:
    case ZAR_T_DECODE: {
      /* Nested values are scanned over the whole child of each batch. */
      int64_t n_children = p->target == ZAR_T_STRUCT ? p->n_children : 1;
      for (int64_t k = 0; k < n_children; k++) {
        struct zar_plan *child =
            (p->target == ZAR_T_FACTOR || p->target == ZAR_T_DECODE) ? p->dict
                                                                     : &p->children[k];
        struct zar_slice *cs = (struct zar_slice *)R_alloc(
            (size_t)(n_slices > 0 ? n_slices : 1), sizeof(struct zar_slice));
        for (int64_t b = 0; b < n_slices; b++) {
          const struct ArrowArrayView *v = slices[b].view;
          if (p->target == ZAR_T_STRUCT && top) {
            cs[b] = zar_field_slice(&slices[b], k);
          } else {
            const struct ArrowArrayView *cv =
                child == p->dict           ? v->dictionary
                : p->target == ZAR_T_REE   ? v->children[1]
                : p->target == ZAR_T_STRUCT ? v->children[k]
                                           : v->children[0];
            cs[b] = (struct zar_slice){cv, 0, cv->length, NULL, NULL};
          }
        }
        int code = zar_resolve(child, cs, n_slices, lossy,
                               p->target == ZAR_T_STRUCT && top, warned, e);
        if (code != NANOARROW_OK) return code;
      }
      if (p->target == ZAR_T_FACTOR && p->dict->target != ZAR_T_CHR) {
        p->target = ZAR_T_DECODE;
      }
      if (p->target == ZAR_T_FACTOR) {
        /* A factor needs unique, non-null levels in every batch. */
        for (int64_t b = 0; b < n_slices && p->target == ZAR_T_FACTOR; b++) {
          const struct ArrowArrayView *d = slices[b].view->dictionary;
          for (int64_t i = 0; i < d->length; i++) {
            if (ArrowArrayViewIsNull(d, i)) {
              p->target = ZAR_T_DECODE;
              break;
            }
          }
        }
      }
      return NANOARROW_OK;
    }
    default:
      break;
  }

  if (p->never) {
    ArrowErrorSet(&e->error, "%s has no R form", ArrowTypeString(p->sv.type));
    return zar_fail(e, "lossy", -1, p->schema->format);
  }

  int64_t bad_row = -1;
  char value[64] = "";
  if (p->lossy_by_schema) {
    bad_row = -2;
  } else if (p->scan != ZAR_SCAN_NONE) {
    int64_t offset = 0;
    for (int64_t b = 0; b < n_slices && bad_row < 0; b++) {
      int64_t i = zar_scan_slice(p, &slices[b]);
      if (i >= 0) {
        bad_row = offset + i;
        zar_describe_value(p, &slices[b], i, value, sizeof(value));
      }
      offset += slices[b].length;
    }
  }
  if (bad_row == -1) return NANOARROW_OK;

  int text_ok = zar_has_text_form(p->sv.type) && p->scan != ZAR_SCAN_NUL;
  if (lossy == ZAR_LOSSY_CHARACTER && text_ok) {
    p->target = ZAR_T_TEXT;
    return NANOARROW_OK;
  }
  if (lossy == ZAR_LOSSY_WARN || lossy == ZAR_LOSSY_ALLOW) {
    p->target = p->lossy_target;
    if (lossy == ZAR_LOSSY_WARN) *warned = 1;
    return NANOARROW_OK;
  }
  if (bad_row >= 0 && top) {
    ArrowErrorSet(&e->error, "row %ld holds %s", (long)(bad_row + 1), value);
    return zar_fail(e, "lossy", bad_row, p->schema->format);
  }
  if (bad_row >= 0) {
    ArrowErrorSet(&e->error, "a nested %s value holds %s",
                  ArrowTypeString(p->sv.type), value);
  } else {
    ArrowErrorSet(&e->error, "%s has no exact R form here",
                  ArrowTypeString(p->sv.type));
  }
  return zar_fail(e, "lossy", -1, p->schema->format);
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
  /* The remainder, not value - secs * scale, which overflows near INT64_MIN. */
  int64_t frac = value % scale;
  if (frac < 0) frac += scale;
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

/* ---- scalar fill ------------------------------------------------------- */

/* The bytes of string element i of a slice, cut at the first NUL, after
   the checks every R string needs: valid UTF-8 and within R's length. */
static int zar_string_bytes(const struct zar_plan *p, const struct zar_slice *s,
                            int64_t i, struct ArrowBufferView *out,
                            struct zar_err *e) {
  *out = ArrowArrayViewGetBytesUnsafe(s->view, zar_j(s, i));
  int64_t len = out->size_bytes;
  const char *nul = len > 0 ? memchr(out->data.data, 0, (size_t)len) : NULL;
  if (nul != NULL) len = nul - out->data.as_char;
  if (zar_utf8_invalid_at(out->data.as_uint8, len) >= 0) {
    ArrowErrorSet(&e->error, "element %ld is not valid UTF-8", (long)i + 1);
    return zar_fail(e, "format", -1, p->schema->format);
  }
  if (len > INT_MAX) {
    ArrowErrorSet(&e->error, "element %ld is longer than R's string limit",
                  (long)i + 1);
    return zar_fail(e, "limit", -1, p->schema->format);
  }
  out->size_bytes = len;
  return NANOARROW_OK;
}

static int zar_fill(const struct zar_plan *p, const struct zar_slice *s,
                    SEXP out, R_xlen_t at, struct ArrowBuffer *scratch,
                    struct zar_err *e) {
  const struct ArrowArrayView *v = s->view;
  int64_t n = s->length;
  int plain = zar_is_plain(s);
  switch (p->target) {
    case ZAR_T_NULL:
    case ZAR_T_LGL: {
      int *dst = LOGICAL(out) + at;
      for (int64_t i = 0; i < n; i++) {
        if (p->target == ZAR_T_NULL || zar_is_null(s, i)) {
          dst[i] = NA_LOGICAL;
        } else {
          dst[i] = ArrowArrayViewGetIntUnsafe(v, zar_j(s, i)) != 0;
        }
      }
      return NANOARROW_OK;
    }
    case ZAR_T_INT: {
      int *dst = INTEGER(out) + at;
      if (n == 0) return NANOARROW_OK;
      if (v->storage_type == NANOARROW_TYPE_INT32 && plain) {
        memcpy(dst, v->buffer_views[1].data.as_int32 + v->offset + s->start,
               (size_t)n * sizeof(int32_t));
        return NANOARROW_OK;
      }
      for (int64_t i = 0; i < n; i++) {
        if (zar_is_null(s, i)) {
          dst[i] = NA_INTEGER;
          continue;
        }
        int64_t j = zar_j(s, i);
        if (v->storage_type == NANOARROW_TYPE_UINT64) {
          uint64_t u = ArrowArrayViewGetUIntUnsafe(v, j);
          dst[i] = u > INT32_MAX ? NA_INTEGER : (int)u;
        } else {
          int64_t x = ArrowArrayViewGetIntUnsafe(v, j);
          dst[i] = (x > INT32_MAX || x < INT32_MIN) ? NA_INTEGER : (int)x;
        }
      }
      return NANOARROW_OK;
    }
    case ZAR_T_DBL: {
      double *dst = REAL(out) + at;
      enum ArrowType t = v->storage_type;
      if (n == 0) return NANOARROW_OK;
      if (t == NANOARROW_TYPE_DOUBLE && plain) {
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
        if (zar_is_null(s, i)) {
          dst[i] = NA_REAL;
          continue;
        }
        int64_t j = zar_j(s, i);
        if (decimal) {
          const char *text;
          if (zar_text(p, v, j, scratch, buf, sizeof(buf), &text) !=
              NANOARROW_OK) {
            ArrowErrorSet(&e->error, "cannot allocate a decimal's text");
            return zar_fail(e, NULL, -1, p->schema->format);
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
                     : (double)ArrowArrayViewGetIntUnsafe(v, zar_j(s, i)) / scale;
      }
      return NANOARROW_OK;
    }
    case ZAR_T_INT64: {
      int64_t *dst = (int64_t *)REAL(out) + at;
      for (int64_t i = 0; i < n; i++) {
        /* bit64's NA is INT64_MIN. */
        dst[i] = zar_is_null(s, i) ? INT64_MIN
                                   : ArrowArrayViewGetIntUnsafe(v, zar_j(s, i));
      }
      return NANOARROW_OK;
    }
    case ZAR_T_CHR: {
      for (int64_t i = 0; i < n; i++) {
        if (zar_is_null(s, i)) {
          SET_STRING_ELT(out, at + (R_xlen_t)i, NA_STRING);
          continue;
        }
        struct ArrowBufferView b;
        if (zar_string_bytes(p, s, i, &b, e) != NANOARROW_OK) return EINVAL;
        SET_STRING_ELT(out, at + (R_xlen_t)i,
                       b.size_bytes == 0
                           ? R_BlankString
                           : Rf_mkCharLenCE(b.data.as_char, (int)b.size_bytes, CE_UTF8));
      }
      return NANOARROW_OK;
    }
    case ZAR_T_BLOB: {
      for (int64_t i = 0; i < n; i++) {
        if (zar_is_null(s, i)) continue;
        struct ArrowBufferView b = ArrowArrayViewGetBytesUnsafe(v, zar_j(s, i));
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
        if (zar_text(p, v, zar_j(s, i), scratch, buf, sizeof(buf), &text) !=
            NANOARROW_OK) {
          ArrowErrorSet(&e->error, "cannot allocate a decimal's text");
          return zar_fail(e, NULL, -1, p->schema->format);
        }
        SET_STRING_ELT(out, at + (R_xlen_t)i, Rf_mkCharCE(text, CE_UTF8));
      }
      return NANOARROW_OK;
    }
    default:
      return NANOARROW_OK;
  }
}

static SEXPTYPE zar_sexptype(enum zar_target t) {
  switch (t) {
    case ZAR_T_NULL:
    case ZAR_T_LGL:
      return LGLSXP;
    case ZAR_T_INT:
    case ZAR_T_FACTOR:
      return INTSXP;
    case ZAR_T_CHR:
    case ZAR_T_TEXT:
      return STRSXP;
    case ZAR_T_BLOB:
    case ZAR_T_STRUCT:
    case ZAR_T_LIST:
    case ZAR_T_FSL:
    case ZAR_T_MAP:
    case ZAR_T_SKIP:
      return VECSXP;
    default:
      return REALSXP;
  }
}

/* ---- attributes -------------------------------------------------------- */

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

static void zar_set_view_attr(SEXP x, const char *name,
                              struct ArrowStringView value) {
  SEXP v;
  if (zar_utf8_invalid_at((const uint8_t *)value.data, value.size_bytes) < 0 &&
      (value.size_bytes == 0 || memchr(value.data, 0, (size_t)value.size_bytes) == NULL)) {
    SEXP chr = PROTECT(Rf_mkCharLenCE(value.data, (int)value.size_bytes, CE_UTF8));
    v = PROTECT(Rf_ScalarString(chr));
    Rf_setAttrib(x, Rf_install(name), v);
    UNPROTECT(2);
    return;
  }
  v = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)value.size_bytes));
  if (value.size_bytes > 0) memcpy(RAW(v), value.data, (size_t)value.size_bytes);
  Rf_setAttrib(x, Rf_install(name), v);
  UNPROTECT(1);
}

static void zar_set_rownames(SEXP df, int64_t rows) {
  SEXP rn = PROTECT(Rf_allocVector(INTSXP, 2));
  INTEGER(rn)[0] = NA_INTEGER;
  INTEGER(rn)[1] = -(int)rows;
  Rf_setAttrib(df, R_RowNamesSymbol, rn);
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
    case ZAR_T_MAP: {
      SEXP sorted = PROTECT(Rf_allocVector(LGLSXP, 1));
      LOGICAL(sorted)[0] = (p->schema->flags & ARROW_FLAG_MAP_KEYS_SORTED) != 0;
      Rf_setAttrib(x, Rf_install("arrow_keys_sorted"), sorted);
      UNPROTECT(1);
      break;
    }
    default:
      break;
  }
  if (p->sv.extension_name.size_bytes > 0) {
    zar_set_view_attr(x, "arrow_extension", p->sv.extension_name);
    if (p->sv.extension_metadata.size_bytes > 0) {
      zar_set_view_attr(x, "arrow_extension_metadata", p->sv.extension_metadata);
    }
  }
}

/* ---- levels: the union of every batch's dictionary --------------------- */

struct zar_levels {
  int64_t n, cap;
  const char **data;
  int64_t *len;
  int64_t *table; /* open addressing, -1 empty */
  int64_t table_cap;
};

static uint64_t zar_hash(const char *s, int64_t n) {
  uint64_t h = 1469598103934665603ULL;
  for (int64_t i = 0; i < n; i++) {
    h ^= (uint8_t)s[i];
    h *= 1099511628211ULL;
  }
  return h;
}

static void zar_levels_grow(struct zar_levels *l) {
  int64_t cap = l->table_cap == 0 ? 64 : l->table_cap * 2;
  int64_t *table = (int64_t *)R_alloc((size_t)cap, sizeof(int64_t));
  for (int64_t i = 0; i < cap; i++) table[i] = -1;
  for (int64_t k = 0; k < l->n; k++) {
    uint64_t h = zar_hash(l->data[k], l->len[k]) & (uint64_t)(cap - 1);
    while (table[h] >= 0) h = (h + 1) & (uint64_t)(cap - 1);
    table[h] = k;
  }
  l->table = table;
  l->table_cap = cap;
  if (l->cap < cap / 2) {
    int64_t new_cap = cap / 2;
    const char **data = (const char **)R_alloc((size_t)new_cap, sizeof(char *));
    int64_t *len = (int64_t *)R_alloc((size_t)new_cap, sizeof(int64_t));
    if (l->n > 0) {
      memcpy(data, l->data, (size_t)l->n * sizeof(char *));
      memcpy(len, l->len, (size_t)l->n * sizeof(int64_t));
    }
    l->data = data;
    l->len = len;
    l->cap = new_cap;
  }
}

/* The level index of the bytes, adding them when new. */
static int64_t zar_levels_add(struct zar_levels *l, const char *s, int64_t n) {
  if (2 * (l->n + 1) > l->table_cap) zar_levels_grow(l);
  uint64_t h = zar_hash(s, n) & (uint64_t)(l->table_cap - 1);
  while (l->table[h] >= 0) {
    int64_t k = l->table[h];
    if (l->len[k] == n && memcmp(l->data[k], s, (size_t)n) == 0) return k;
    h = (h + 1) & (uint64_t)(l->table_cap - 1);
  }
  l->data[l->n] = s;
  l->len[l->n] = n;
  l->table[h] = l->n;
  return l->n++;
}

/* ---- building ---------------------------------------------------------- */

static SEXP zar_build(struct zar_plan *p, struct zar_slice *slices,
                      int64_t n_slices, int64_t rows, struct ArrowBuffer *text,
                      struct zar_err *e);

/* A list column: element i is the R form of its child range. */
static SEXP zar_build_list(struct zar_plan *p, struct zar_slice *slices,
                           int64_t n_slices, int64_t rows,
                           struct ArrowBuffer *text, struct zar_err *e) {
  SEXP out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)rows));
  struct zar_plan *item = &p->children[0];
  int64_t fixed = p->sv.fixed_size;
  R_xlen_t at = 0;
  for (int64_t b = 0; b < n_slices; b++) {
    const struct zar_slice *s = &slices[b];
    const struct ArrowArrayView *child = s->view->children[0];
    for (int64_t i = 0; i < s->length; i++, at++) {
      if (zar_is_null(s, i)) continue;
      int64_t begin, end;
      zar_list_range(s->view, zar_j(s, i), fixed, &begin, &end);
      if (begin < 0 || end < begin || end > child->length) {
        ArrowErrorSet(&e->error, "list element %ld has a range outside its child",
                      (long)i + 1);
        UNPROTECT(1);
        zar_fail(e, "format", -1, p->schema->format);
        return R_NilValue;
      }
      struct zar_slice cs = {child, begin, end - begin, NULL, NULL};
      SEXP value = zar_build(item, &cs, 1, end - begin, text, e);
      if (e->kind != NULL) {
        UNPROTECT(1);
        return R_NilValue;
      }
      SET_VECTOR_ELT(out, at, value);
    }
  }
  if (p->target == ZAR_T_MAP) {
    /* Section 6.4: the entries are data frames named key and value. */
    for (R_xlen_t k = 0; k < (R_xlen_t)rows; k++) {
      SEXP df = VECTOR_ELT(out, k);
      if (df == R_NilValue || Rf_xlength(df) != 2) continue;
      SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
      SET_STRING_ELT(names, 0, Rf_mkChar("key"));
      SET_STRING_ELT(names, 1, Rf_mkChar("value"));
      Rf_setAttrib(df, R_NamesSymbol, names);
      UNPROTECT(1);
    }
  }
  UNPROTECT(1);
  return out;
}

/* A fixed_size_list as an n-column matrix, NA rows for null elements. */
static SEXP zar_build_matrix(struct zar_plan *p, struct zar_slice *slices,
                             int64_t n_slices, int64_t rows,
                             struct ArrowBuffer *text, struct zar_err *e) {
  struct zar_plan *item = &p->children[0];
  int64_t width = p->sv.fixed_size;
  SEXP flat = PROTECT(Rf_allocVector(zar_sexptype(item->target), (R_xlen_t)(rows * width)));
  R_xlen_t at = 0;
  for (int64_t b = 0; b < n_slices; b++) {
    const struct zar_slice *s = &slices[b];
    for (int64_t i = 0; i < s->length; i++) {
      int64_t begin, end;
      zar_list_range(s->view, zar_j(s, i), width, &begin, &end);
      struct zar_slice cs = {s->view->children[0], begin, width, NULL, NULL};
      if (zar_fill(item, &cs, flat, at, text, e) != NANOARROW_OK) {
        UNPROTECT(1);
        return R_NilValue;
      }
      if (zar_is_null(s, i)) {
        for (int64_t k = 0; k < width; k++) {
          switch (TYPEOF(flat)) {
            case LGLSXP: LOGICAL(flat)[at + k] = NA_LOGICAL; break;
            case INTSXP: INTEGER(flat)[at + k] = NA_INTEGER; break;
            case REALSXP: REAL(flat)[at + k] = NA_REAL; break;
            default: SET_STRING_ELT(flat, at + k, NA_STRING); break;
          }
        }
      }
      at += width;
    }
  }
  /* Row-major to R's column-major. */
  SEXP out = PROTECT(Rf_allocMatrix(TYPEOF(flat), (int)rows, (int)width));
  for (int64_t r = 0; r < rows; r++) {
    for (int64_t k = 0; k < width; k++) {
      R_xlen_t from = (R_xlen_t)(r * width + k), to = (R_xlen_t)(r + k * rows);
      switch (TYPEOF(flat)) {
        case LGLSXP: LOGICAL(out)[to] = LOGICAL(flat)[from]; break;
        case INTSXP: INTEGER(out)[to] = INTEGER(flat)[from]; break;
        case REALSXP: REAL(out)[to] = REAL(flat)[from]; break;
        default: SET_STRING_ELT(out, to, STRING_ELT(flat, from)); break;
      }
    }
  }
  zar_decorate(item, out);
  UNPROTECT(2);
  return out;
}

static SEXP zar_build_factor(struct zar_plan *p, struct zar_slice *slices,
                             int64_t n_slices, int64_t rows, struct zar_err *e) {
  SEXP codes = PROTECT(Rf_allocVector(INTSXP, (R_xlen_t)rows));
  struct zar_levels levels;
  memset(&levels, 0, sizeof(levels));
  R_xlen_t at = 0;
  for (int64_t b = 0; b < n_slices; b++) {
    const struct zar_slice *s = &slices[b];
    const struct ArrowArrayView *d = s->view->dictionary;
    int64_t *remap = (int64_t *)R_alloc((size_t)(d->length > 0 ? d->length : 1),
                                        sizeof(int64_t));
    for (int64_t k = 0; k < d->length; k++) {
      struct ArrowBufferView v = ArrowArrayViewGetBytesUnsafe(d, k);
      if (zar_utf8_invalid_at(v.data.as_uint8, v.size_bytes) >= 0) {
        ArrowErrorSet(&e->error, "dictionary value %ld is not valid UTF-8", (long)k + 1);
        UNPROTECT(1);
        zar_fail(e, "format", -1, p->schema->format);
        return R_NilValue;
      }
      remap[k] = zar_levels_add(&levels, v.data.as_char, v.size_bytes);
    }
    for (int64_t i = 0; i < s->length; i++, at++) {
      if (zar_is_null(s, i)) {
        INTEGER(codes)[at] = NA_INTEGER;
        continue;
      }
      int64_t idx = ArrowArrayViewGetIntUnsafe(s->view, zar_j(s, i));
      if (idx < 0 || idx >= d->length) {
        ArrowErrorSet(&e->error, "dictionary index %ld is out of range", (long)idx);
        UNPROTECT(1);
        zar_fail(e, "format", -1, p->schema->format);
        return R_NilValue;
      }
      INTEGER(codes)[at] = (int)remap[idx] + 1;
    }
  }
  if (levels.n > INT_MAX) {
    ArrowErrorSet(&e->error, "the dictionary has more levels than a factor holds");
    UNPROTECT(1);
    zar_fail(e, "limit", -1, p->schema->format);
    return R_NilValue;
  }
  SEXP lv = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)levels.n));
  for (int64_t k = 0; k < levels.n; k++) {
    SET_STRING_ELT(lv, (R_xlen_t)k,
                   Rf_mkCharLenCE(levels.data[k], (int)levels.len[k], CE_UTF8));
  }
  Rf_setAttrib(codes, R_LevelsSymbol, lv);
  if (p->schema->flags & ARROW_FLAG_DICTIONARY_ORDERED) {
    zar_set_class(codes, "ordered", "factor");
  } else {
    zar_set_class(codes, "factor", NULL);
  }
  UNPROTECT(2);
  return codes;
}

/* Builds the R form of a plan over its slices. On failure returns
   R_NilValue with e->kind set. */
/* ---- deferred strings -------------------------------------------------- */

/* Whether a string column can be deferred: copy = FALSE, plain string or
   large_string storage read directly (not through a dictionary or a
   run-end encoding), and no enclosing struct with nulls. Anything else is
   copied as before. */
static int zar_deferrable(const struct zar_plan *p, const struct zar_slice *slices,
                          int64_t n_slices, const struct zar_err *e) {
  if (e->copy || p->target != ZAR_T_CHR || e->arrays == NULL || e->arrays == R_NilValue) {
    return 0;
  }
  for (int64_t b = 0; b < n_slices; b++) {
    const struct zar_slice *s = &slices[b];
    if (s->view->storage_type != NANOARROW_TYPE_STRING &&
        s->view->storage_type != NANOARROW_TYPE_LARGE_STRING) {
      return 0;
    }
    if (s->map != NULL) return 0;
    for (const struct zar_slice *up = s->up; up != NULL; up = up->up) {
      if (up->map != NULL || up->view->null_count != 0) return 0;
    }
  }
  return 1;
}

/* Checks every value as the copying fill does, so a deferred column fails
   in the same way and at the same time, then wraps the buffers. */
static SEXP zar_build_deferred(const struct zar_plan *p, const struct zar_slice *slices,
                               int64_t n_slices, struct zar_err *e) {
  struct zar_deferred_chunk *chunks = (struct zar_deferred_chunk *)R_alloc(
      (size_t)(n_slices > 0 ? n_slices : 1), sizeof(struct zar_deferred_chunk));
  int64_t begin = 0;
  for (int64_t b = 0; b < n_slices; b++) {
    const struct zar_slice *s = &slices[b];
    const struct ArrowArrayView *v = s->view;
    for (int64_t i = 0; i < s->length; i++) {
      if (zar_is_null(s, i)) continue;
      struct ArrowBufferView bytes;
      if (zar_string_bytes(p, s, i, &bytes, e) != NANOARROW_OK) return R_NilValue;
    }
    int large = v->storage_type == NANOARROW_TYPE_LARGE_STRING;
    int64_t first = v->offset + s->start;
    chunks[b].begin = begin;
    chunks[b].length = s->length;
    chunks[b].offsets = v->buffer_views[1].data.as_uint8 +
                        first * (int64_t)(large ? sizeof(int64_t) : sizeof(int32_t));
    chunks[b].data = v->buffer_views[2].data.as_char;
    chunks[b].validity = v->null_count != 0 ? v->buffer_views[0].data.as_uint8 : NULL;
    chunks[b].validity_offset = first;
    chunks[b].batch = b;
    chunks[b].large = large;
    begin += s->length;
  }
  return zar_deferred_strings(e->arrays, chunks, n_slices);
}

static SEXP zar_build(struct zar_plan *p, struct zar_slice *slices,
                      int64_t n_slices, int64_t rows, struct ArrowBuffer *text,
                      struct zar_err *e) {
  SEXP out = R_NilValue;
  switch (p->target) {
    case ZAR_T_SKIP:
      return R_NilValue;
    case ZAR_T_STRUCT: {
      out = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)p->n_children));
      SEXP names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)p->n_children));
      struct zar_slice *cs = (struct zar_slice *)R_alloc(
          (size_t)(n_slices > 0 ? n_slices : 1), sizeof(struct zar_slice));
      for (int64_t k = 0; k < p->n_children; k++) {
        const char *name = p->children[k].schema->name;
        SET_STRING_ELT(names, (R_xlen_t)k, Rf_mkCharCE(name == NULL ? "" : name, CE_UTF8));
        for (int64_t b = 0; b < n_slices; b++) cs[b] = zar_field_slice(&slices[b], k);
        SEXP col = zar_build(&p->children[k], cs, n_slices, rows, text, e);
        if (e->kind != NULL) {
          UNPROTECT(2);
          return R_NilValue;
        }
        SET_VECTOR_ELT(out, (R_xlen_t)k, col);
      }
      Rf_setAttrib(out, R_NamesSymbol, names);
      zar_set_class(out, "data.frame", NULL);
      zar_set_rownames(out, rows);
      UNPROTECT(2);
      break;
    }
    case ZAR_T_LIST:
    case ZAR_T_FSL:
    case ZAR_T_MAP:
      out = zar_build_list(p, slices, n_slices, rows, text, e);
      if (e->kind != NULL) return R_NilValue;
      break;
    case ZAR_T_MATRIX:
      out = zar_build_matrix(p, slices, n_slices, rows, text, e);
      if (e->kind != NULL) return R_NilValue;
      return out;
    case ZAR_T_FACTOR:
      out = zar_build_factor(p, slices, n_slices, rows, e);
      if (e->kind != NULL) return R_NilValue;
      break;
    case ZAR_T_DECODE:
    case ZAR_T_REE: {
      struct zar_slice *ms = (struct zar_slice *)R_alloc(
          (size_t)(n_slices > 0 ? n_slices : 1), sizeof(struct zar_slice));
      for (int64_t b = 0; b < n_slices; b++) {
        ms[b] = p->target == ZAR_T_DECODE ? zar_dictionary_slice(&slices[b])
                                          : zar_ree_slice(&slices[b]);
      }
      struct zar_plan *values = p->target == ZAR_T_DECODE ? p->dict : &p->children[0];
      out = zar_build(values, ms, n_slices, rows, text, e);
      if (e->kind != NULL) return R_NilValue;
      break;
    }
    default: {
      if (zar_deferrable(p, slices, n_slices, e)) {
        out = zar_build_deferred(p, slices, n_slices, e);
        if (e->kind != NULL) return R_NilValue;
        break;
      }
      out = PROTECT(Rf_allocVector(zar_sexptype(p->target), (R_xlen_t)rows));
      R_xlen_t at = 0;
      for (int64_t b = 0; b < n_slices; b++) {
        if (zar_fill(p, &slices[b], out, at, text, e) != NANOARROW_OK) {
          UNPROTECT(1);
          return R_NilValue;
        }
        at += (R_xlen_t)slices[b].length;
      }
      UNPROTECT(1);
      break;
    }
  }
  PROTECT(out);
  if (p->target != ZAR_T_DECODE && p->target != ZAR_T_REE) zar_decorate(p, out);
  UNPROTECT(1);
  return out;
}

/* ---- the entry point --------------------------------------------------- */

/* Converts the batches in `arrays` (array handles of one schema) to R.
   With `frame` TRUE the schema is a struct and each field is a column;
   otherwise the array itself is the one column. `opts` is
   list(lossy, to, int64, frame, max_depth, copy): `to` an integer code
   per column, `int64` whether bit64's integer64 may be used, `copy` FALSE
   to defer string columns.

   Returns list(columns, names, warned, rows), or a failure with the
   column, row, format and name. */
SEXP zar_c_to_r(SEXP arrays, SEXP schema_xptr, SEXP opts) {
  struct zar_err e;
  memset(&e, 0, sizeof(e));
  struct ArrowSchema *schema = zar_schema_from_xptr(schema_xptr, &e.error);
  if (schema == NULL) return zar_failure_from_error("handle", &e.error);

  int lossy = Rf_asInteger(VECTOR_ELT(opts, 0));
  SEXP to = VECTOR_ELT(opts, 1);
  int int64_ok = Rf_asLogical(VECTOR_ELT(opts, 2));
  int frame = Rf_asLogical(VECTOR_ELT(opts, 3));
  int max_depth = Rf_asInteger(VECTOR_ELT(opts, 4));
  e.copy = Rf_xlength(opts) > 5 ? Rf_asLogical(VECTOR_ELT(opts, 5)) != FALSE : 1;
  e.arrays = arrays;

  R_xlen_t n_batches = Rf_xlength(arrays);
  for (R_xlen_t b = 0; b < n_batches; b++) {
    if (zar_array_from_xptr(VECTOR_ELT(arrays, b), &e.error) == NULL) {
      return zar_failure_from_error("handle", &e.error);
    }
  }

  struct ArrowSchemaView top;
  if (ArrowSchemaViewInit(&top, schema, &e.error) != NANOARROW_OK) {
    return zar_failure_from_error("format", &e.error);
  }
  if (frame && top.type != NANOARROW_TYPE_STRUCT) {
    return zar_failure("type", "a data frame needs a struct schema");
  }
  int64_t n_cols = frame ? schema->n_children : 1;

  /* The scratch owns the views from here on. */
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
  if (sc->views == NULL) {
    UNPROTECT(1);
    return zar_failure(NULL, "cannot allocate conversion scratch");
  }

  int64_t rows = 0;
  for (R_xlen_t b = 0; b < n_batches; b++) {
    struct ArrowArray *array =
        (struct ArrowArray *)R_ExternalPtrAddr(VECTOR_ELT(arrays, b));
    int code = ArrowArrayViewInitFromSchema(&sc->views[b], schema, &e.error);
    sc->n = (int64_t)b + 1;
    if (code == NANOARROW_OK) {
      code = ArrowArrayViewSetArray(&sc->views[b], array, &e.error);
    }
    /* Views are read below; nanoarrow checks none of their ranges. */
    if (code == NANOARROW_OK) code = zar_view_check_layout(&sc->views[b], "", &e.error);
    if (code != NANOARROW_OK) {
      UNPROTECT(1);
      return zar_failure_from_error("format", &e.error);
    }
    rows += sc->views[b].length;
  }
  if (rows > R_XLEN_T_MAX) {
    UNPROTECT(1);
    return zar_failure("limit", "the batches hold more rows than R allows");
  }

  /* The batch-level slices, and each column's slices. */
  struct zar_slice *batch = (struct zar_slice *)R_alloc(
      (size_t)(n_batches > 0 ? n_batches : 1), sizeof(struct zar_slice));
  for (R_xlen_t b = 0; b < n_batches; b++) {
    batch[b] = (struct zar_slice){&sc->views[b], 0, sc->views[b].length, NULL, NULL};
  }
  struct zar_plan *plans =
      (struct zar_plan *)R_alloc((size_t)(n_cols > 0 ? n_cols : 1), sizeof(struct zar_plan));
  struct zar_slice **col_slices = (struct zar_slice **)R_alloc(
      (size_t)(n_cols > 0 ? n_cols : 1), sizeof(struct zar_slice *));
  int *warned = (int *)R_alloc((size_t)(n_cols > 0 ? n_cols : 1), sizeof(int));

  for (int64_t c = 0; c < n_cols; c++) {
    struct zar_plan *p = &plans[c];
    const struct ArrowSchema *cs = frame ? schema->children[c] : schema;
    warned[c] = 0;
    col_slices[c] = (struct zar_slice *)R_alloc(
        (size_t)(n_batches > 0 ? n_batches : 1), sizeof(struct zar_slice));
    for (R_xlen_t b = 0; b < n_batches; b++) {
      col_slices[c][b] = frame ? zar_field_slice(&batch[b], c) : batch[b];
    }

    int code = zar_plan_init(p, cs, 1, max_depth, &e);
    int target_to = Rf_xlength(to) > c ? INTEGER(to)[c] : ZAR_TO_NONE;
    if (code == NANOARROW_OK) code = zar_plan_to(p, target_to, &e);
    if (code == NANOARROW_OK && p->sv.type == NANOARROW_TYPE_INT64 &&
        lossy == ZAR_LOSSY_ALLOW && int64_ok && target_to == ZAR_TO_NONE) {
      p->target = ZAR_T_INT64;
      p->scan = ZAR_SCAN_NONE;
    }
    if (code == NANOARROW_OK) {
      code = zar_resolve(p, col_slices[c], n_batches, lossy, 1, &warned[c], &e);
    }
    if (code != NANOARROW_OK) {
      UNPROTECT(1);
      return zar_column_failure(e.kind == NULL ? "type" : e.kind, e.error.message,
                                (int)c + 1, e.row >= 0 ? (double)(e.row + 1) : NA_REAL,
                                e.format == NULL ? cs->format : e.format, cs->name);
    }
  }

  SEXP columns = PROTECT(Rf_allocVector(VECSXP, (R_xlen_t)n_cols));
  SEXP names = PROTECT(Rf_allocVector(STRSXP, (R_xlen_t)n_cols));
  struct ArrowBuffer text;
  ArrowBufferInit(&text);
  for (int64_t c = 0; c < n_cols; c++) {
    struct zar_plan *p = &plans[c];
    SET_STRING_ELT(names, (R_xlen_t)c,
                   Rf_mkCharCE(p->schema->name == NULL ? "" : p->schema->name, CE_UTF8));
    SEXP col = zar_build(p, col_slices[c], n_batches, rows, &text, &e);
    if (e.kind != NULL) {
      ArrowBufferReset(&text);
      UNPROTECT(3);
      return zar_column_failure(e.kind, e.error.message, (int)c + 1, NA_REAL,
                                e.format == NULL ? p->schema->format : e.format,
                                p->schema->name);
    }
    SET_VECTOR_ELT(columns, (R_xlen_t)c, col);
  }
  ArrowBufferReset(&text);

  int n_warned = 0;
  for (int64_t c = 0; c < n_cols; c++) n_warned += warned[c];
  SEXP warned_out = PROTECT(Rf_allocVector(INTSXP, n_warned));
  for (int64_t c = 0, k = 0; c < n_cols; c++) {
    if (warned[c]) INTEGER(warned_out)[k++] = (int)c + 1;
  }

  const char *out_names[] = {"columns", "names", "warned", "rows", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, out_names));
  SET_VECTOR_ELT(out, 0, columns);
  SET_VECTOR_ELT(out, 1, names);
  SET_VECTOR_ELT(out, 2, warned_out);
  SET_VECTOR_ELT(out, 3, Rf_ScalarReal((double)rows));

  zar_scratch_free(sc);
  UNPROTECT(5);
  return out;
}
