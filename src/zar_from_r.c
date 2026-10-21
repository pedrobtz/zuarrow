/* R to Arrow (design sections 6.2, 6.9): builds an array of a given schema
   from rows [start, start + n) of an R vector or data frame, writing
   buffers directly. Every NA becomes a null bit over a zeroed slot. A value
   the schema cannot hold exactly is reported, never rounded, except that
   POSIXct and difftime round to the schema's unit (D10). */
#include <inttypes.h>
#include <math.h>
#include <string.h>

#include "zar.h"

struct zar_build {
  struct ArrowError error;
  const char *kind; /* the failure's kind when a build fails */
  double row;       /* 1-based, or NA */
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

/* Writes the validity bitmap of rows [start, start + n) when any is NA. */
static int zar_set_validity(struct ArrowArray *array, SEXP x, R_xlen_t start,
                            int64_t n, zar_is_na_fn is_na,
                            struct zar_build *b) {
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

static void *zar_data(struct ArrowArray *array, int i, int64_t bytes,
                      struct zar_build *b) {
  struct ArrowBuffer *buffer = ArrowArrayBuffer(array, i);
  if (ArrowBufferReserve(buffer, bytes) != NANOARROW_OK) {
    ArrowErrorSet(&b->error, "cannot allocate %" PRId64 " bytes", bytes);
    return NULL;
  }
  void *out = buffer->data + buffer->size_bytes;
  memset(out, 0, (size_t)bytes);
  buffer->size_bytes += bytes;
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
  void *data = zar_data(array, 1, n * zar_type_bytes(t), b);
  if (data == NULL) return zar_build_fail(b, NULL, NA_REAL);

  if (is_int && t == NANOARROW_TYPE_INT32 && array->null_count == 0) {
    memcpy(data, INTEGER(x) + start, (size_t)n * sizeof(int32_t));
    return NANOARROW_OK;
  }
  if (!is_int && t == NANOARROW_TYPE_DOUBLE && scale == 1.0) {
    const double *src = REAL(x) + start;
    double *dst = (double *)data;
    for (int64_t i = 0; i < n; i++) dst[i] = R_IsNA(src[i]) ? 0.0 : src[i];
    return NANOARROW_OK;
  }

  for (int64_t i = 0; i < n; i++) {
    R_xlen_t k = start + (R_xlen_t)i;
    if (is_na(x, k)) continue;
    double v = is_int ? (double)INTEGER(x)[k] : REAL(x)[k];
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
    if (!R_FINITE(v) || v != floor(v) || !zar_int_fits(t, v)) {
      ArrowErrorSet(&b->error, "row %" PRId64 " holds %.17g, which %s cannot hold exactly",
                    (int64_t)k + 1, is_int ? (double)INTEGER(x)[k] : REAL(x)[k],
                    ArrowTypeString(t));
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
  const int *src = LOGICAL(x) + start;
  for (int64_t i = 0; i < n; i++) {
    if (src[i] != NA_LOGICAL && src[i]) ArrowBitSet(data, i);
  }
  return NANOARROW_OK;
}

/* ---- strings and bytes ------------------------------------------------- */

/* The UTF-8 bytes of a string. translateCharUTF8() returns the CHARSXP's
   own bytes when no translation is needed, and then its length is known
   without a strlen(). */
static const char *zar_utf8(SEXP s, size_t *len) {
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
      zar_utf8(s, &len);
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
      const char *u = zar_utf8(s, &len);
      memcpy(data + at, u, len);
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

  if (t == NANOARROW_TYPE_STRUCT) {
    return zar_build_struct(array, schema, x, start, n, b);
  }
  if (Rf_inherits(x, "data.frame") || Rf_isFactor(x)) {
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
    if (s != NA_STRING) {
      zar_utf8(s, &len);
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
  if (code == NANOARROW_OK) {
    code = ArrowArrayFinishBuildingDefault(array, &b.error);
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
