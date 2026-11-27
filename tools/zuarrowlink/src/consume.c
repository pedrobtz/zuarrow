/* Consumes zuarrow's C API as a reader will: the header and the bundled
 * nanoarrow off the LinkingTo include path, the code from the installed
 * libzuarrow.a, and nothing of zuarrow's R namespace.
 *
 *   C_build_stream   builds two batches of the eight column families the
 *                    consumer zugodb accepts (b, i, l, g, u, z, tdD,
 *                    tsu:UTC) with the archive's builders, and hands them
 *                    out as an ArrowBasicArrayStream.
 *   C_read_ipc       opens an IPC file through zuarrow_open_stream().
 *   C_stream_columns converts a stream of those families to R vectors here,
 *                    in C, so the tests need no zuarrow to read values.
 *
 * R objects are made only when no C object that a longjmp would leak is
 * live: a stream is owned by its external pointer, and the batches being
 * converted by a holder external pointer whose finalizer releases them.
 */
#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>

#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include <zuarrow.h>
#include <zuarrow/nanoarrow.h>

/* ---- stream handles in nanoarrow's r.h layout ------------------------ */

static void stream_finalize(SEXP x) {
  struct ArrowArrayStream *s = (struct ArrowArrayStream *)R_ExternalPtrAddr(x);
  if (s == NULL) return;
  if (s->release != NULL) s->release(s);
  free(s);
  R_ClearExternalPtr(x);
}

static SEXP stream_handle(void) {
  struct ArrowArrayStream *s =
      (struct ArrowArrayStream *)calloc(1, sizeof(struct ArrowArrayStream));
  if (s == NULL) Rf_error("cannot allocate a stream");
  SEXP x = PROTECT(R_MakeExternalPtr(s, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(x, stream_finalize, TRUE);
  Rf_setAttrib(x, R_ClassSymbol, Rf_mkString("nanoarrow_array_stream"));
  UNPROTECT(1);
  return x;
}

static struct ArrowArrayStream *stream_of(SEXP x) {
  struct ArrowArrayStream *s =
      TYPEOF(x) == EXTPTRSXP ? (struct ArrowArrayStream *)R_ExternalPtrAddr(x) : NULL;
  if (s == NULL || s->release == NULL) Rf_error("not a live stream handle");
  return s;
}

/* ---- building with the archive's nanoarrow --------------------------- */

static const char *formats[] = {"b", "i", "l", "g", "u", "z", "tdD", "tsu:UTC"};
static const char *names[] = {"b", "i", "l", "g", "u", "z", "d", "t"};
#define N_COLUMNS 8

static int build_schema(struct ArrowSchema *schema) {
  ArrowSchemaInit(schema);
  int code = ArrowSchemaSetTypeStruct(schema, N_COLUMNS);
  for (int k = 0; code == NANOARROW_OK && k < N_COLUMNS; k++) {
    code = ArrowSchemaSetFormat(schema->children[k], formats[k]);
    if (code == NANOARROW_OK) code = ArrowSchemaSetName(schema->children[k], names[k]);
  }
  return code;
}

/* One row of every column; `null` appends a null instead. */
struct row {
  int null;
  int b;
  int32_t i;
  int64_t l;
  double g;
  const char *u;
  const uint8_t *z;
  int64_t z_size;
  int32_t d;
  int64_t t;
};

static int append_row(struct ArrowArray *array, const struct row *r) {
  int code = NANOARROW_OK;
  for (int k = 0; code == NANOARROW_OK && k < N_COLUMNS; k++) {
    struct ArrowArray *c = array->children[k];
    if (r->null) {
      code = ArrowArrayAppendNull(c, 1);
      continue;
    }
    switch (k) {
      case 0: code = ArrowArrayAppendInt(c, r->b); break;
      case 1: code = ArrowArrayAppendInt(c, r->i); break;
      case 2: code = ArrowArrayAppendInt(c, r->l); break;
      case 3: code = ArrowArrayAppendDouble(c, r->g); break;
      case 4: {
        struct ArrowStringView v = {r->u, (int64_t)strlen(r->u)};
        code = ArrowArrayAppendString(c, v);
        break;
      }
      case 5: {
        struct ArrowBufferView v;
        v.data.as_uint8 = r->z;
        v.size_bytes = r->z_size;
        code = ArrowArrayAppendBytes(c, v);
        break;
      }
      case 6: code = ArrowArrayAppendInt(c, r->d); break;
      case 7: code = ArrowArrayAppendInt(c, r->t); break;
    }
  }
  if (code == NANOARROW_OK) code = ArrowArrayFinishElement(array);
  return code;
}

static int build_batch(const struct ArrowSchema *schema, const struct row *rows, int n,
                       struct ArrowArray *out, struct ArrowError *error) {
  int code = ArrowArrayInitFromSchema(out, schema, error);
  if (code != NANOARROW_OK) return code;
  code = ArrowArrayStartAppending(out);
  for (int k = 0; code == NANOARROW_OK && k < n; k++) code = append_row(out, &rows[k]);
  if (code == NANOARROW_OK) code = ArrowArrayFinishBuildingDefault(out, error);
  if (code != NANOARROW_OK) out->release(out);
  return code;
}

SEXP C_build_stream(void) {
  static const uint8_t z1[] = {1, 2, 3};
  static const uint8_t z4[] = {255};
  const struct row first[] = {
      {0, 1, 1, INT64_C(9007199254740992), 1.5, "a", z1, 3, 0, 0},
      {1, 0, 0, 0, 0, "", NULL, 0, 0, 0},
      {0, 0, -2147483647, -1, -INFINITY, "\xc3\xa9", z1, 0, 20784,
       INT64_C(1764201600500000)},
  };
  const struct row second[] = {{0, 1, 42, 0, 0.25, "", z4, 1, -1, -1}};

  SEXP out = PROTECT(stream_handle());
  struct ArrowArrayStream *stream = (struct ArrowArrayStream *)R_ExternalPtrAddr(out);
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowSchema schema;
  struct ArrowArray batches[2];
  batches[0].release = batches[1].release = NULL;
  int code = build_schema(&schema);
  if (code == NANOARROW_OK) code = build_batch(&schema, first, 3, &batches[0], &error);
  if (code == NANOARROW_OK) code = build_batch(&schema, second, 1, &batches[1], &error);
  if (code == NANOARROW_OK) code = ArrowBasicArrayStreamInit(stream, &schema, 2);
  if (code == NANOARROW_OK) {
    ArrowBasicArrayStreamSetArray(stream, 0, &batches[0]);
    ArrowBasicArrayStreamSetArray(stream, 1, &batches[1]);
    code = ArrowBasicArrayStreamValidate(stream, &error);
  } else if (schema.release != NULL) {
    schema.release(&schema);
  }
  if (code != NANOARROW_OK) {
    for (int k = 0; k < 2; k++) {
      if (batches[k].release != NULL) batches[k].release(&batches[k]);
    }
    char message[sizeof(error.message) + 32];
    snprintf(message, sizeof(message), "building failed (%d): %s", code, error.message);
    UNPROTECT(1);
    Rf_error("%s", message);
  }
  UNPROTECT(1);
  return out;
}

/* ---- reading through zuarrow_open_stream() --------------------------- */

/* list(stream, code, kind, message): the stream on success, otherwise the
   error stream's code, zuarrow_error_kind() and get_last_error(). */
SEXP C_read_ipc(SEXP path, SEXP columns, SEXP limits) {
  zuarrow_options options;
  zuarrow_options_init(&options);
  const char **selected = NULL;
  if (!Rf_isNull(columns)) {
    R_xlen_t n = Rf_xlength(columns);
    selected = (const char **)R_alloc(n > 0 ? (size_t)n : 1, sizeof(char *));
    for (R_xlen_t k = 0; k < n; k++) {
      selected[k] = Rf_translateCharUTF8(STRING_ELT(columns, k));
    }
    options.columns = selected;
    options.n_columns = (int64_t)n;
  }
  if (!Rf_isNull(limits)) options.max_bytes = REAL(limits)[0];
  const char *c_path = R_ExpandFileName(Rf_translateChar(STRING_ELT(path, 0)));

  SEXP handle = PROTECT(stream_handle());
  struct ArrowArrayStream *stream = (struct ArrowArrayStream *)R_ExternalPtrAddr(handle);
  int code = zuarrow_open_stream(c_path, &options, stream);
  char message[1024] = "";
  const char *kind = NULL;
  if (code != 0 && stream->release != NULL) {
    kind = zuarrow_error_kind(stream);
    snprintf(message, sizeof(message), "%s", stream->get_last_error(stream));
    stream->release(stream);
  }
  const char *fields[] = {"stream", "code", "kind", "message", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, fields));
  if (code == 0) SET_VECTOR_ELT(out, 0, handle);
  SET_VECTOR_ELT(out, 1, Rf_ScalarInteger(code));
  if (kind != NULL) SET_VECTOR_ELT(out, 2, Rf_mkString(kind));
  SET_VECTOR_ELT(out, 3, Rf_mkString(message));
  UNPROTECT(2);
  return out;
}

/* ---- converting in C ------------------------------------------------- */

struct holder {
  struct ArrowSchema schema;
  struct ArrowArray *arrays;
  struct ArrowArrayView *views;
  int64_t n;
  int64_t n_views;
};

static void holder_free(struct holder *h) {
  for (int64_t k = 0; k < h->n_views; k++) ArrowArrayViewReset(&h->views[k]);
  for (int64_t k = 0; k < h->n; k++) {
    if (h->arrays[k].release != NULL) h->arrays[k].release(&h->arrays[k]);
  }
  if (h->schema.release != NULL) h->schema.release(&h->schema);
  free(h->arrays);
  free(h->views);
  free(h);
}

static void holder_finalize(SEXP x) {
  struct holder *h = (struct holder *)R_ExternalPtrAddr(x);
  if (h != NULL) holder_free(h);
  R_ClearExternalPtr(x);
}

/* Reads every batch of the stream into a holder, C only. Returns 0, or
   the code with `message` set. */
static int holder_fill(struct holder *h, struct ArrowArrayStream *s, char *message,
                       size_t size) {
  int code = s->get_schema(s, &h->schema);
  if (code != 0) {
    snprintf(message, size, "get_schema: %s", s->get_last_error(s));
    return code;
  }
  for (;;) {
    struct ArrowArray *grown =
        (struct ArrowArray *)realloc(h->arrays, (size_t)(h->n + 1) * sizeof(*grown));
    if (grown == NULL) return ENOMEM;
    h->arrays = grown;
    h->arrays[h->n].release = NULL;
    code = s->get_next(s, &h->arrays[h->n]);
    if (code != 0) {
      const char *e = s->get_last_error(s);
      snprintf(message, size, "%s", e == NULL ? "get_next failed" : e);
      return code;
    }
    if (h->arrays[h->n].release == NULL) break;
    h->n++;
  }
  h->views = (struct ArrowArrayView *)calloc(h->n > 0 ? (size_t)h->n : 1, sizeof(*h->views));
  if (h->views == NULL) return ENOMEM;
  struct ArrowError error;
  for (int64_t k = 0; k < h->n; k++) {
    code = ArrowArrayViewInitFromSchema(&h->views[k], &h->schema, &error);
    if (code != 0) break;
    h->n_views++;
    code = ArrowArrayViewSetArray(&h->views[k], &h->arrays[k], &error);
    if (code != 0) break;
  }
  if (code != 0) snprintf(message, size, "view: %s", error.message);
  return code;
}

static SEXP column(struct holder *h, int64_t j, R_xlen_t n) {
  const char *format = h->schema.children[j]->format;
  SEXPTYPE type = REALSXP;
  if (strcmp(format, "b") == 0) type = LGLSXP;
  if (strcmp(format, "i") == 0) type = INTSXP;
  if (strcmp(format, "u") == 0) type = STRSXP;
  if (strcmp(format, "z") == 0) type = VECSXP;
  SEXP out = PROTECT(Rf_allocVector(type, n));
  R_xlen_t at = 0;
  for (int64_t k = 0; k < h->n; k++) {
    const struct ArrowArrayView *v = h->views[k].children[j];
    for (int64_t i = 0; i < v->length; i++, at++) {
      int null = ArrowArrayViewIsNull(v, i);
      switch (type) {
        case LGLSXP:
          LOGICAL(out)[at] = null ? NA_LOGICAL : (int)ArrowArrayViewGetIntUnsafe(v, i);
          break;
        case INTSXP:
          INTEGER(out)[at] = null ? NA_INTEGER : (int)ArrowArrayViewGetIntUnsafe(v, i);
          break;
        case STRSXP: {
          if (null) {
            SET_STRING_ELT(out, at, NA_STRING);
          } else {
            struct ArrowStringView s = ArrowArrayViewGetStringUnsafe(v, i);
            SET_STRING_ELT(out, at, Rf_mkCharLenCE(s.data, (int)s.size_bytes, CE_UTF8));
          }
          break;
        }
        case VECSXP: {
          if (!null) {
            struct ArrowBufferView b = ArrowArrayViewGetBytesUnsafe(v, i);
            SEXP raw = Rf_allocVector(RAWSXP, (R_xlen_t)b.size_bytes);
            SET_VECTOR_ELT(out, at, raw);
            if (b.size_bytes > 0) memcpy(RAW(raw), b.data.data, (size_t)b.size_bytes);
          }
          break;
        }
        default:
          /* l, tdD and tsu: as doubles of their integer values, g as is. */
          if (null) {
            REAL(out)[at] = NA_REAL;
          } else if (strcmp(format, "g") == 0) {
            REAL(out)[at] = ArrowArrayViewGetDoubleUnsafe(v, i);
          } else {
            REAL(out)[at] = (double)ArrowArrayViewGetIntUnsafe(v, i);
          }
      }
    }
  }
  UNPROTECT(1);
  return out;
}

/* list(columns, formats, batches): every column as an R vector, the
   format strings, and the rows of each batch. */
SEXP C_stream_columns(SEXP x) {
  struct ArrowArrayStream *s = stream_of(x);
  struct holder *h = (struct holder *)calloc(1, sizeof(struct holder));
  if (h == NULL) Rf_error("cannot allocate");
  SEXP keep = PROTECT(R_MakeExternalPtr(h, R_NilValue, R_NilValue));
  R_RegisterCFinalizerEx(keep, holder_finalize, TRUE);
  char message[1100] = "";
  int code = holder_fill(h, s, message, sizeof(message));
  if (code != 0) {
    holder_finalize(keep);
    UNPROTECT(1);
    Rf_error("reading the stream failed (%d): %s", code, message);
  }
  for (int64_t j = 0; j < h->schema.n_children; j++) {
    const char *f = h->schema.children[j]->format;
    if (strcmp(f, "b") && strcmp(f, "i") && strcmp(f, "l") && strcmp(f, "g") &&
        strcmp(f, "u") && strcmp(f, "z") && strcmp(f, "tdD") && strncmp(f, "tsu:", 4)) {
      char bad[64];
      snprintf(bad, sizeof(bad), "%s", f);
      holder_finalize(keep);
      UNPROTECT(1);
      Rf_error("no conversion for format '%s'", bad);
    }
  }
  R_xlen_t rows = 0;
  for (int64_t k = 0; k < h->n; k++) rows += (R_xlen_t)h->arrays[k].length;
  int64_t n = h->schema.n_children;
  SEXP cols = PROTECT(Rf_allocVector(VECSXP, n));
  SEXP col_names = PROTECT(Rf_allocVector(STRSXP, n));
  SEXP fmts = PROTECT(Rf_allocVector(STRSXP, n));
  SEXP batches = PROTECT(Rf_allocVector(REALSXP, h->n));
  for (int64_t j = 0; j < n; j++) {
    SET_VECTOR_ELT(cols, j, column(h, j, rows));
    const char *name = h->schema.children[j]->name;
    SET_STRING_ELT(col_names, j, Rf_mkCharCE(name == NULL ? "" : name, CE_UTF8));
    SET_STRING_ELT(fmts, j, Rf_mkChar(h->schema.children[j]->format));
  }
  for (int64_t k = 0; k < h->n; k++) REAL(batches)[k] = (double)h->arrays[k].length;
  Rf_setAttrib(cols, R_NamesSymbol, col_names);
  holder_finalize(keep);
  const char *fields[] = {"columns", "formats", "batches", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, fields));
  SET_VECTOR_ELT(out, 0, cols);
  SET_VECTOR_ELT(out, 1, fmts);
  SET_VECTOR_ELT(out, 2, batches);
  UNPROTECT(6);
  return out;
}

/* ---- the exact parsers and the ABI ----------------------------------- */

SEXP C_parse(SEXP what, SEXP x) {
  int date = strcmp(CHAR(STRING_ELT(what, 0)), "date") == 0;
  R_xlen_t n = Rf_xlength(x);
  SEXP code = PROTECT(Rf_allocVector(INTSXP, n));
  SEXP value = PROTECT(Rf_allocVector(REALSXP, n));
  for (R_xlen_t i = 0; i < n; i++) {
    int64_t v = 0;
    const char *s = Rf_translateCharUTF8(STRING_ELT(x, i));
    int rc = date ? zuarrow_parse_date(s, &v) : zuarrow_parse_int64(s, &v);
    INTEGER(code)[i] = rc == 0 ? 0 : (rc == ERANGE ? 2 : 1);
    REAL(value)[i] = rc == 0 ? (double)v : NA_REAL;
  }
  const char *fields[] = {"code", "value", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, fields));
  SET_VECTOR_ELT(out, 0, code);
  SET_VECTOR_ELT(out, 1, value);
  UNPROTECT(3);
  return out;
}

SEXP C_abi(void) {
  SEXP out = PROTECT(Rf_allocVector(INTSXP, 2));
  INTEGER(out)[0] = ZUARROW_ABI_VERSION;
  INTEGER(out)[1] = (int)zuarrow_abi_version();
  UNPROTECT(1);
  return out;
}

static const R_CallMethodDef calls[] = {
    {"C_build_stream", (DL_FUNC)&C_build_stream, 0},
    {"C_read_ipc", (DL_FUNC)&C_read_ipc, 3},
    {"C_stream_columns", (DL_FUNC)&C_stream_columns, 1},
    {"C_parse", (DL_FUNC)&C_parse, 2},
    {"C_abi", (DL_FUNC)&C_abi, 0},
    {NULL, NULL, 0}};

void attribute_visible R_init_zuarrowlink(DllInfo *dll) {
  R_registerRoutines(dll, NULL, calls, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
}
