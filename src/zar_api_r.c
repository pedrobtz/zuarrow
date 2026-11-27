/* Test entry points over the public C API (src/zar_api.c), for
   tests/testthat/test-c-api.R: R reaches zuarrow_open_stream() with the
   options a C caller would build, and gets the stream back as a zuarrow
   stream handle that arrow_to_r() converts. Not used by any exported
   function. */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "zar.h"
#include "zuarrow.h"
#include "zukomp-r.h"

/* list(code, kind, message, stream, schema_code, next_code, next_message):
   `stream` is the handle on success and NULL on failure, when the error
   stream's get_schema() and get_next() codes and get_next()'s message are
   reported and the stream released. `codecs` is "zukomp", "none",
   "bad-abi" or "short", or "bad-count" for no table and n_columns 1 with
   no columns; `struct_size` NA means sizeof(zuarrow_options);
   `limits` NULL with every other option NULL passes NULL options. */
SEXP zar_c_api_open(SEXP path, SEXP columns, SEXP indices, SEXP limits, SEXP codecs,
                    SEXP struct_size) {
  const char *mode = CHAR(STRING_ELT(codecs, 0));
  zukomp_api_v1 altered;
  const zukomp_api_v1 *table = NULL;
  if (strcmp(mode, "none") != 0 && strcmp(mode, "bad-count") != 0) {
    table = zukomp_api();
    if (strcmp(mode, "bad-abi") == 0 || strcmp(mode, "short") == 0) {
      altered = *table;
      if (mode[0] == 'b') {
        altered.abi_version = ZUKOMP_ABI_VERSION + 1;
      } else {
        altered.struct_size = (uint32_t)offsetof(zukomp_api_v1, decompress_one);
      }
      table = &altered;
    }
  }

  zuarrow_options options;
  zuarrow_options_init(&options);
  int null_options = Rf_isNull(limits) && Rf_isNull(columns) && Rf_isNull(indices) &&
                     strcmp(mode, "none") == 0 && INTEGER(struct_size)[0] == NA_INTEGER;
  if (!Rf_isNull(limits)) {
    options.max_message = REAL(limits)[0];
    options.max_depth = (int32_t)REAL(limits)[1];
    options.max_batch_rows = REAL(limits)[2];
    options.max_bytes = REAL(limits)[3];
    options.max_dictionary = REAL(limits)[4];
  }
  options.codecs = table;
  if (INTEGER(struct_size)[0] != NA_INTEGER) {
    options.struct_size = (uint32_t)INTEGER(struct_size)[0];
  }
  const char **names = NULL;
  int64_t *idx = NULL;
  if (!Rf_isNull(columns)) {
    R_xlen_t n = Rf_xlength(columns);
    names = (const char **)R_alloc(n > 0 ? (size_t)n : 1, sizeof(char *));
    for (R_xlen_t k = 0; k < n; k++) {
      names[k] = STRING_ELT(columns, k) == NA_STRING
                     ? NULL
                     : Rf_translateCharUTF8(STRING_ELT(columns, k));
    }
    options.columns = names;
    options.n_columns = (int64_t)n;
  }
  if (!Rf_isNull(indices)) {
    R_xlen_t n = Rf_xlength(indices);
    idx = (int64_t *)R_alloc(n > 0 ? (size_t)n : 1, sizeof(int64_t));
    for (R_xlen_t k = 0; k < n; k++) idx[k] = (int64_t)REAL(indices)[k];
    options.column_indices = idx;
    options.n_columns = (int64_t)n;
  }
  if (strcmp(mode, "bad-count") == 0) options.n_columns = 1;
  const char *c_path = Rf_isNull(path) ? NULL : R_ExpandFileName(Rf_translateChar(STRING_ELT(path, 0)));

  SEXP handle = PROTECT(zar_stream_owning_xptr());
  struct ArrowArrayStream *stream = (struct ArrowArrayStream *)R_ExternalPtrAddr(handle);
  int code = zuarrow_open_stream(c_path, null_options ? NULL : &options, stream);

  char message[1024] = "";
  char next_message[1024] = "";
  const char *kind = NULL;
  int schema_code = NA_INTEGER, next_code = NA_INTEGER;
  if (code != 0 && stream->release != NULL) {
    kind = zuarrow_error_kind(stream);
    snprintf(message, sizeof(message), "%s", stream->get_last_error(stream));
    struct ArrowSchema schema;
    schema.release = NULL;
    schema_code = stream->get_schema(stream, &schema);
    if (schema.release != NULL) schema.release(&schema);
    struct ArrowArray array;
    array.release = (void (*)(struct ArrowArray *))1;
    next_code = stream->get_next(stream, &array);
    if (array.release != NULL) next_code = -1; /* left unreleased: a bug */
    snprintf(next_message, sizeof(next_message), "%s", stream->get_last_error(stream));
    stream->release(stream);
  }

  const char *names_out[] = {"code", "kind", "message", "stream", "schema_code",
                             "next_code", "next_message", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, names_out));
  SET_VECTOR_ELT(out, 0, Rf_ScalarInteger(code));
  if (kind != NULL) SET_VECTOR_ELT(out, 1, Rf_mkString(kind));
  SET_VECTOR_ELT(out, 2, zar_scalar_utf8(message));
  if (code == 0) SET_VECTOR_ELT(out, 3, handle);
  SET_VECTOR_ELT(out, 4, Rf_ScalarInteger(schema_code));
  SET_VECTOR_ELT(out, 5, Rf_ScalarInteger(next_code));
  SET_VECTOR_ELT(out, 6, zar_scalar_utf8(next_message));
  UNPROTECT(2);
  return out;
}

/* zuarrow_error_kind() of a stream handle, NULL when it names none. */
SEXP zar_c_api_kind(SEXP x) {
  struct ArrowError error;
  struct ArrowArrayStream *stream = zar_stream_from_xptr(x, &error);
  if (stream == NULL) return zar_failure_from_error("handle", &error);
  const char *kind = zuarrow_error_kind(stream);
  return kind == NULL ? R_NilValue : Rf_mkString(kind);
}

/* The public parsers over a character vector: list(code, value), each
   value as text ("" where the code is not 0). `what` is "int64",
   "uint64", "date", "instant", "time" or "decimal"; `digits` the
   fraction digits, or for a decimal c(bit width, precision, scale). */
SEXP zar_c_api_parse(SEXP what, SEXP x, SEXP digits, SEXP utc) {
  const char *w = CHAR(STRING_ELT(what, 0));
  R_xlen_t n = Rf_xlength(x);
  SEXP code = PROTECT(Rf_allocVector(INTSXP, n));
  SEXP value = PROTECT(Rf_allocVector(STRSXP, n));
  for (R_xlen_t i = 0; i < n; i++) {
    const char *s = Rf_translateCharUTF8(STRING_ELT(x, i));
    char buf[160] = "";
    int rc = EINVAL;
    if (strcmp(w, "int64") == 0) {
      int64_t v;
      rc = zuarrow_parse_int64(s, &v);
      if (rc == 0) snprintf(buf, sizeof(buf), "%" PRId64, v);
    } else if (strcmp(w, "uint64") == 0) {
      uint64_t v;
      rc = zuarrow_parse_uint64(s, &v);
      if (rc == 0) snprintf(buf, sizeof(buf), "%" PRIu64, v);
    } else if (strcmp(w, "date") == 0) {
      int64_t v;
      rc = zuarrow_parse_date(s, &v);
      if (rc == 0) snprintf(buf, sizeof(buf), "%" PRId64, v);
    } else if (strcmp(w, "instant") == 0) {
      int64_t v;
      rc = zuarrow_parse_instant(s, INTEGER(digits)[0], Rf_asLogical(utc), &v);
      if (rc == 0) snprintf(buf, sizeof(buf), "%" PRId64, v);
    } else if (strcmp(w, "time") == 0) {
      int64_t v;
      rc = zuarrow_parse_time(s, INTEGER(digits)[0], &v);
      if (rc == 0) snprintf(buf, sizeof(buf), "%" PRId64, v);
    } else if (strcmp(w, "decimal") == 0) {
      struct ArrowDecimal d;
      ArrowDecimalInit(&d, INTEGER(digits)[0], INTEGER(digits)[1], INTEGER(digits)[2]);
      rc = zuarrow_parse_decimal(s, &d);
      if (rc == 0) {
        /* Freed before the next R allocation, which could longjmp. */
        struct ArrowBuffer text;
        ArrowBufferInit(&text);
        if (ArrowDecimalAppendDigitsToBuffer(&d, &text) == NANOARROW_OK) {
          size_t m = (size_t)text.size_bytes < sizeof(buf) - 1 ? (size_t)text.size_bytes
                                                               : sizeof(buf) - 1;
          memcpy(buf, text.data, m);
          buf[m] = '\0';
        }
        ArrowBufferReset(&text);
      }
    }
    INTEGER(code)[i] = rc;
    SET_STRING_ELT(value, i, Rf_mkCharCE(buf, CE_UTF8));
  }
  const char *names[] = {"code", "value", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, names));
  SET_VECTOR_ELT(out, 0, code);
  SET_VECTOR_ELT(out, 1, value);
  UNPROTECT(3);
  return out;
}

/* zuarrow_utf8_invalid_at() of a raw vector. */
SEXP zar_c_api_utf8(SEXP x) {
  return Rf_ScalarReal(
      (double)zuarrow_utf8_invalid_at(RAW(x), (int64_t)Rf_xlength(x)));
}
