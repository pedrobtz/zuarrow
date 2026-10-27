/* Handles: external pointers in nanoarrow's r.h layout (design D6, D7,
   section 6.1), the failure objects C returns to R, and the schema tools
   that need nothing beyond a schema: copy, printing and the spec round
   trip the R layer builds schemas through. */
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "zar.h"

/* ---- strings ------------------------------------------------------------ */

/* A length-one character vector from UTF-8 bytes, with the CHARSXP held
   while the vector is allocated. */
SEXP zar_scalar_utf8(const char *x) {
  SEXP chr = PROTECT(Rf_mkCharCE(x, CE_UTF8));
  SEXP out = Rf_ScalarString(chr);
  UNPROTECT(1);
  return out;
}

/* ---- failures ----------------------------------------------------------- */

SEXP zar_failure(const char *kind, const char *message) {
  SEXP out = PROTECT(Rf_allocVector(VECSXP, 2));
  SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
  SET_STRING_ELT(names, 0, Rf_mkChar("kind"));
  SET_STRING_ELT(names, 1, Rf_mkChar("message"));
  Rf_setAttrib(out, R_NamesSymbol, names);
  SET_VECTOR_ELT(out, 0, kind == NULL ? R_NilValue : Rf_mkString(kind));
  SET_VECTOR_ELT(out, 1, zar_scalar_utf8(message));
  SEXP cls = PROTECT(Rf_mkString("zar_failure"));
  Rf_setAttrib(out, R_ClassSymbol, cls);
  UNPROTECT(3);
  return out;
}

SEXP zar_failure_from_error(const char *kind, const struct ArrowError *error) {
  return zar_failure(kind, error->message);
}

/* translateCharUTF8() returns the CHARSXP's own bytes when no translation
   is needed; then its length is known without a strlen(), and nothing has
   checked the bytes. A translation from another encoding is valid by
   construction. A "bytes" string is refused before translateCharUTF8()
   can raise on it. */
const char *zar_char_utf8(SEXP s, size_t *len) {
  if (Rf_getCharCE(s) == CE_BYTES) return NULL;
  const char *u = Rf_translateCharUTF8(s);
  if (u == CHAR(s)) {
    *len = (size_t)LENGTH(s);
    if (zar_utf8_invalid_at((const uint8_t *)u, (int64_t)*len) >= 0) {
      return NULL;
    }
  } else {
    *len = strlen(u);
  }
  return u;
}

/* ---- owning handles ----------------------------------------------------- */

static void zar_finalize_schema(SEXP xptr) {
  struct ArrowSchema *schema = (struct ArrowSchema *)R_ExternalPtrAddr(xptr);
  if (schema != NULL && schema->release != NULL) {
    schema->release(schema);
  }
  if (schema != NULL) {
    free(schema);
    R_ClearExternalPtr(xptr);
  }
}

static void zar_finalize_array(SEXP xptr) {
  struct ArrowArray *array = (struct ArrowArray *)R_ExternalPtrAddr(xptr);
  if (array != NULL && array->release != NULL) {
    array->release(array);
  }
  if (array != NULL) {
    free(array);
    R_ClearExternalPtr(xptr);
  }
}

static void zar_finalize_stream(SEXP xptr) {
  struct ArrowArrayStream *stream =
      (struct ArrowArrayStream *)R_ExternalPtrAddr(xptr);
  if (stream != NULL && stream->release != NULL) {
    stream->release(stream);
  }
  if (stream != NULL) {
    free(stream);
    R_ClearExternalPtr(xptr);
  }
}

static SEXP zar_class2(const char *first, const char *second) {
  SEXP cls = PROTECT(Rf_allocVector(STRSXP, 2));
  SET_STRING_ELT(cls, 0, Rf_mkChar(first));
  SET_STRING_ELT(cls, 1, Rf_mkChar(second));
  UNPROTECT(1);
  return cls;
}

/* The struct is allocated before the external pointer so that a failed
   R allocation cannot leak it: R_MakeExternalPtr is the only call that can
   longjmp between malloc() and the finalizer taking ownership, and the
   finalizer is registered on the very next line. */
SEXP zar_schema_owning_xptr(void) {
  struct ArrowSchema *schema =
      (struct ArrowSchema *)malloc(sizeof(struct ArrowSchema));
  if (schema == NULL) {
    Rf_error("zuarrow: cannot allocate an ArrowSchema");
  }
  schema->release = NULL;
  SEXP xptr = PROTECT(R_MakeExternalPtr(schema, R_NilValue, R_NilValue));
  R_RegisterCFinalizer(xptr, &zar_finalize_schema);
  SEXP cls = PROTECT(zar_class2("zuarrow_schema", "nanoarrow_schema"));
  Rf_setAttrib(xptr, R_ClassSymbol, cls);
  UNPROTECT(2);
  return xptr;
}

SEXP zar_array_owning_xptr(SEXP schema_xptr) {
  struct ArrowArray *array =
      (struct ArrowArray *)malloc(sizeof(struct ArrowArray));
  if (array == NULL) {
    Rf_error("zuarrow: cannot allocate an ArrowArray");
  }
  array->release = NULL;
  SEXP xptr = PROTECT(R_MakeExternalPtr(array, schema_xptr, R_NilValue));
  R_RegisterCFinalizer(xptr, &zar_finalize_array);
  SEXP cls = PROTECT(zar_class2("zuarrow_array", "nanoarrow_array"));
  Rf_setAttrib(xptr, R_ClassSymbol, cls);
  UNPROTECT(2);
  return xptr;
}

SEXP zar_stream_owning_xptr(void) {
  struct ArrowArrayStream *stream =
      (struct ArrowArrayStream *)malloc(sizeof(struct ArrowArrayStream));
  if (stream == NULL) {
    Rf_error("zuarrow: cannot allocate an ArrowArrayStream");
  }
  stream->release = NULL;
  SEXP xptr = PROTECT(R_MakeExternalPtr(stream, R_NilValue, R_NilValue));
  R_RegisterCFinalizer(xptr, &zar_finalize_stream);
  SEXP cls =
      PROTECT(zar_class2("zuarrow_array_stream", "nanoarrow_array_stream"));
  Rf_setAttrib(xptr, R_ClassSymbol, cls);
  UNPROTECT(2);
  return xptr;
}

/* ---- readers ------------------------------------------------------------ */

static void *zar_xptr_addr(SEXP x, const char *cls, const char *what,
                           struct ArrowError *error) {
  if (TYPEOF(x) != EXTPTRSXP || !Rf_inherits(x, cls)) {
    ArrowErrorSet(error, "expected %s handle", what);
    return NULL;
  }
  void *addr = R_ExternalPtrAddr(x);
  if (addr == NULL) {
    ArrowErrorSet(error, "the %s handle points to NULL", what);
    return NULL;
  }
  return addr;
}

struct ArrowSchema *zar_schema_from_xptr(SEXP x, struct ArrowError *error) {
  struct ArrowSchema *schema = (struct ArrowSchema *)zar_xptr_addr(
      x, "nanoarrow_schema", "a schema", error);
  if (schema != NULL && schema->release == NULL) {
    ArrowErrorSet(error, "the schema handle has been released");
    return NULL;
  }
  return schema;
}

struct ArrowArray *zar_array_from_xptr(SEXP x, struct ArrowError *error) {
  struct ArrowArray *array = (struct ArrowArray *)zar_xptr_addr(
      x, "nanoarrow_array", "an array", error);
  if (array != NULL && array->release == NULL) {
    ArrowErrorSet(error, "the array handle has been released");
    return NULL;
  }
  return array;
}

struct ArrowArrayStream *zar_stream_from_xptr(SEXP x, struct ArrowError *error) {
  struct ArrowArrayStream *stream = (struct ArrowArrayStream *)zar_xptr_addr(
      x, "nanoarrow_array_stream", "a stream", error);
  if (stream != NULL && stream->release == NULL) {
    ArrowErrorSet(error, "the stream handle has been released or consumed");
    return NULL;
  }
  return stream;
}

SEXP zar_array_schema_xptr(SEXP array_xptr, struct ArrowError *error) {
  SEXP tag = R_ExternalPtrTag(array_xptr);
  if (zar_schema_from_xptr(tag, error) == NULL) {
    ArrowErrorSet(error, "the array handle carries no live schema");
    return NULL;
  }
  return tag;
}

const char *zar_handle_status(SEXP x) {
  if (TYPEOF(x) != EXTPTRSXP) return "null";
  void *addr = R_ExternalPtrAddr(x);
  if (addr == NULL) return "null";
  if (Rf_inherits(x, "nanoarrow_schema")) {
    return ((struct ArrowSchema *)addr)->release == NULL ? "released" : "live";
  }
  if (Rf_inherits(x, "nanoarrow_array")) {
    return ((struct ArrowArray *)addr)->release == NULL ? "released" : "live";
  }
  if (Rf_inherits(x, "nanoarrow_array_stream")) {
    return ((struct ArrowArrayStream *)addr)->release == NULL ? "released"
                                                               : "live";
  }
  return "null";
}

SEXP zar_c_handle_status(SEXP x) { return Rf_mkString(zar_handle_status(x)); }

/* ---- schema copy -------------------------------------------------------- */

SEXP zar_schema_copy_of(SEXP x) {
  struct ArrowError error;
  error.message[0] = '\0';
  const struct ArrowSchema *src = NULL;

  if (TYPEOF(x) == EXTPTRSXP && Rf_inherits(x, "nanoarrow_schema")) {
    src = zar_schema_from_xptr(x, &error);
  } else if (TYPEOF(x) == EXTPTRSXP && Rf_inherits(x, "nanoarrow_array")) {
    if (zar_array_from_xptr(x, &error) != NULL) {
      SEXP tag = zar_array_schema_xptr(x, &error);
      if (tag != NULL) src = zar_schema_from_xptr(tag, &error);
    }
  } else if (TYPEOF(x) == EXTPTRSXP &&
             Rf_inherits(x, "nanoarrow_array_stream")) {
    struct ArrowArrayStream *stream = zar_stream_from_xptr(x, &error);
    if (stream == NULL) return zar_failure_from_error("handle", &error);
    SEXP out = PROTECT(zar_schema_owning_xptr());
    struct ArrowSchema *dst = (struct ArrowSchema *)R_ExternalPtrAddr(out);
    int code = stream->get_schema(stream, dst);
    if (code != 0) {
      const char *msg = stream->get_last_error(stream);
      ArrowErrorSet(&error, "the stream could not report its schema: %s",
                    msg == NULL ? strerror(code) : msg);
      UNPROTECT(1);
      return zar_failure_from_error("handle", &error);
    }
    UNPROTECT(1);
    return out;
  } else {
    ArrowErrorSet(&error, "expected a schema, array or stream handle");
  }

  if (src == NULL) return zar_failure_from_error("handle", &error);

  SEXP out = PROTECT(zar_schema_owning_xptr());
  struct ArrowSchema *dst = (struct ArrowSchema *)R_ExternalPtrAddr(out);
  if (ArrowSchemaDeepCopy(src, dst) != NANOARROW_OK) {
    UNPROTECT(1);
    return zar_failure("handle", "the schema could not be copied");
  }
  UNPROTECT(1);
  return out;
}

SEXP zar_c_schema_copy(SEXP x) { return zar_schema_copy_of(x); }

/* ---- printing ----------------------------------------------------------- */

SEXP zar_c_schema_format(SEXP x, SEXP recursive) {
  struct ArrowError error;
  struct ArrowSchema *schema = zar_schema_from_xptr(x, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);
  char rec = (char)Rf_asLogical(recursive);
  int64_t n = ArrowSchemaToString(schema, NULL, 0, rec);
  char *buf = (char *)R_alloc((size_t)n + 1, 1);
  ArrowSchemaToString(schema, buf, n + 1, rec);
  return zar_scalar_utf8(buf);
}

/* ---- the spec round trip ----------------------------------------------- */

/* A schema spec is the R list the R layer builds schemas from and reads
   them into: list(format, name, flags, metadata, children, dictionary),
   with metadata a named list of raw vectors (keys in order, values as
   bytes), children a list of specs and dictionary a spec or NULL. */

static SEXP zar_list_get(SEXP list, const char *name) {
  SEXP names = Rf_getAttrib(list, R_NamesSymbol);
  if (TYPEOF(list) != VECSXP || TYPEOF(names) != STRSXP) return R_NilValue;
  for (R_xlen_t i = 0; i < Rf_xlength(list); i++) {
    if (strcmp(CHAR(STRING_ELT(names, i)), name) == 0) {
      return VECTOR_ELT(list, i);
    }
  }
  return R_NilValue;
}

static int zar_metadata_from_list(SEXP metadata, struct ArrowBuffer *out,
                                  struct ArrowError *error) {
  SEXP names = Rf_getAttrib(metadata, R_NamesSymbol);
  R_xlen_t n = Rf_xlength(metadata);
  if (TYPEOF(metadata) != VECSXP || (n > 0 && TYPEOF(names) != STRSXP)) {
    ArrowErrorSet(error, "metadata must be a named list of raw vectors");
    return EINVAL;
  }
  if (ArrowMetadataBuilderInit(out, NULL) != NANOARROW_OK) {
    ArrowErrorSet(error, "cannot allocate metadata");
    return ENOMEM;
  }
  for (R_xlen_t i = 0; i < n; i++) {
    SEXP value = VECTOR_ELT(metadata, i);
    if (TYPEOF(value) != RAWSXP) {
      ArrowErrorSet(error, "metadata values must be raw vectors");
      return EINVAL;
    }
    size_t key_len;
    const char *key = zar_char_utf8(STRING_ELT(names, i), &key_len);
    if (key == NULL) {
      ArrowErrorSet(error, "a metadata key is not valid UTF-8");
      return EILSEQ;
    }
    struct ArrowStringView k = {key, (int64_t)key_len};
    struct ArrowStringView v = {(const char *)RAW(value),
                                (int64_t)Rf_xlength(value)};
    if (ArrowMetadataBuilderAppend(out, k, v) != NANOARROW_OK) {
      ArrowErrorSet(error, "cannot allocate metadata");
      return ENOMEM;
    }
  }
  return NANOARROW_OK;
}

static int zar_schema_build(struct ArrowSchema *out, SEXP spec,
                            struct ArrowError *error) {
  ArrowSchemaInit(out);
  SEXP format = zar_list_get(spec, "format");
  if (TYPEOF(format) != STRSXP || Rf_xlength(format) != 1 ||
      STRING_ELT(format, 0) == NA_STRING) {
    ArrowErrorSet(error, "a schema spec needs a format string");
    return EINVAL;
  }
  size_t text_len;
  const char *text = zar_char_utf8(STRING_ELT(format, 0), &text_len);
  if (text == NULL) {
    ArrowErrorSet(error, "a format string is not valid UTF-8");
    return EILSEQ;
  }
  if (ArrowSchemaSetFormat(out, text) != NANOARROW_OK) {
    ArrowErrorSet(error, "cannot allocate a format string");
    return ENOMEM;
  }

  SEXP name = zar_list_get(spec, "name");
  if (TYPEOF(name) == STRSXP && Rf_xlength(name) == 1 &&
      STRING_ELT(name, 0) != NA_STRING) {
    text = zar_char_utf8(STRING_ELT(name, 0), &text_len);
    if (text == NULL) {
      ArrowErrorSet(error, "a field name is not valid UTF-8");
      return EILSEQ;
    }
    if (ArrowSchemaSetName(out, text) != NANOARROW_OK) {
      ArrowErrorSet(error, "cannot allocate a field name");
      return ENOMEM;
    }
  }

  SEXP flags = zar_list_get(spec, "flags");
  out->flags = flags == R_NilValue ? ARROW_FLAG_NULLABLE
                                   : (int64_t)Rf_asInteger(flags);

  SEXP metadata = zar_list_get(spec, "metadata");
  if (metadata != R_NilValue && Rf_xlength(metadata) > 0) {
    struct ArrowBuffer buffer;
    int code = zar_metadata_from_list(metadata, &buffer, error);
    if (code == NANOARROW_OK &&
        ArrowSchemaSetMetadata(out, (const char *)buffer.data) !=
            NANOARROW_OK) {
      ArrowErrorSet(error, "cannot allocate metadata");
      code = ENOMEM;
    }
    ArrowBufferReset(&buffer);
    if (code != NANOARROW_OK) return code;
  }

  SEXP children = zar_list_get(spec, "children");
  R_xlen_t n_children = TYPEOF(children) == VECSXP ? Rf_xlength(children) : 0;
  if (n_children > 0) {
    if (ArrowSchemaAllocateChildren(out, (int64_t)n_children) !=
        NANOARROW_OK) {
      ArrowErrorSet(error, "cannot allocate schema children");
      return ENOMEM;
    }
    for (R_xlen_t i = 0; i < n_children; i++) {
      int code = zar_schema_build(out->children[i], VECTOR_ELT(children, i),
                                  error);
      if (code != NANOARROW_OK) return code;
    }
  }

  SEXP dictionary = zar_list_get(spec, "dictionary");
  if (dictionary != R_NilValue) {
    if (ArrowSchemaAllocateDictionary(out) != NANOARROW_OK) {
      ArrowErrorSet(error, "cannot allocate a dictionary schema");
      return ENOMEM;
    }
    int code = zar_schema_build(out->dictionary, dictionary, error);
    if (code != NANOARROW_OK) return code;
  }
  return NANOARROW_OK;
}

/* Checks every node's format parses, naming the path to the first one that
   does not. */
static int zar_schema_check(const struct ArrowSchema *schema, char *path,
                            size_t path_size, struct ArrowError *error) {
  struct ArrowSchemaView view;
  struct ArrowError inner;
  if (ArrowSchemaViewInit(&view, schema, &inner) != NANOARROW_OK) {
    ArrowErrorSet(error, "%s%s", path[0] ? path : "", inner.message);
    return EINVAL;
  }
  size_t len = strlen(path);
  for (int64_t i = 0; i < schema->n_children; i++) {
    snprintf(path + len, path_size - len, "child %ld: ", (long)i);
    int code = zar_schema_check(schema->children[i], path, path_size, error);
    if (code != NANOARROW_OK) return code;
  }
  if (schema->dictionary != NULL) {
    snprintf(path + len, path_size - len, "dictionary: ");
    int code = zar_schema_check(schema->dictionary, path, path_size, error);
    if (code != NANOARROW_OK) return code;
  }
  path[len] = '\0';
  return NANOARROW_OK;
}

SEXP zar_c_schema_from_spec(SEXP spec) {
  struct ArrowError error;
  error.message[0] = '\0';
  SEXP out = PROTECT(zar_schema_owning_xptr());
  struct ArrowSchema *schema = (struct ArrowSchema *)R_ExternalPtrAddr(out);
  int code = zar_schema_build(schema, spec, &error);
  if (code == NANOARROW_OK) {
    char path[512] = "";
    code = zar_schema_check(schema, path, sizeof(path), &error);
    if (code != NANOARROW_OK) {
      UNPROTECT(1);
      return zar_failure_from_error("format", &error);
    }
  }
  UNPROTECT(1);
  if (code != NANOARROW_OK) {
    return zar_failure_from_error(code == EILSEQ ? "type" : NULL, &error);
  }
  return out;
}

static SEXP zar_metadata_to_list(const char *metadata) {
  struct ArrowMetadataReader reader;
  if (metadata == NULL ||
      ArrowMetadataReaderInit(&reader, metadata) != NANOARROW_OK) {
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 0));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 0));
    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(2);
    return out;
  }
  int32_t n = reader.remaining_keys;
  SEXP out = PROTECT(Rf_allocVector(VECSXP, n));
  SEXP names = PROTECT(Rf_allocVector(STRSXP, n));
  struct ArrowStringView key, value;
  for (int32_t i = 0; i < n; i++) {
    if (ArrowMetadataReaderRead(&reader, &key, &value) != NANOARROW_OK) break;
    SET_STRING_ELT(names, i,
                   Rf_mkCharLenCE(key.data, (int)key.size_bytes, CE_UTF8));
    SEXP raw = Rf_allocVector(RAWSXP, (R_xlen_t)value.size_bytes);
    SET_VECTOR_ELT(out, i, raw);
    if (value.size_bytes > 0) {
      memcpy(RAW(raw), value.data, (size_t)value.size_bytes);
    }
  }
  Rf_setAttrib(out, R_NamesSymbol, names);
  UNPROTECT(2);
  return out;
}

static SEXP zar_schema_spec(const struct ArrowSchema *schema) {
  const char *names[] = {"format", "name",     "flags", "metadata",
                         "children", "dictionary", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, names));
  SET_VECTOR_ELT(out, 0,
                 zar_scalar_utf8(schema->format == NULL ? "" : schema->format));
  SET_VECTOR_ELT(out, 1,
                 schema->name == NULL ? Rf_ScalarString(NA_STRING)
                                      : zar_scalar_utf8(schema->name));
  SET_VECTOR_ELT(out, 2, Rf_ScalarInteger((int)schema->flags));
  SET_VECTOR_ELT(out, 3, zar_metadata_to_list(schema->metadata));
  SEXP children = Rf_allocVector(VECSXP, (R_xlen_t)schema->n_children);
  SET_VECTOR_ELT(out, 4, children);
  for (int64_t i = 0; i < schema->n_children; i++) {
    SET_VECTOR_ELT(children, (R_xlen_t)i, zar_schema_spec(schema->children[i]));
  }
  if (schema->dictionary != NULL) {
    SET_VECTOR_ELT(out, 5, zar_schema_spec(schema->dictionary));
  }
  UNPROTECT(1);
  return out;
}

SEXP zar_c_schema_to_spec(SEXP x) {
  struct ArrowError error;
  struct ArrowSchema *schema = zar_schema_from_xptr(x, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);
  return zar_schema_spec(schema);
}

/* ---- metadata ----------------------------------------------------------- */

SEXP zar_c_schema_metadata(SEXP x) {
  struct ArrowError error;
  struct ArrowSchema *schema = zar_schema_from_xptr(x, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);
  return zar_metadata_to_list(schema->metadata);
}

SEXP zar_c_schema_with_metadata(SEXP x, SEXP metadata) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowSchema *schema = zar_schema_from_xptr(x, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);

  struct ArrowBuffer buffer;
  ArrowBufferInit(&buffer);
  int code = NANOARROW_OK;
  if (metadata != R_NilValue && Rf_xlength(metadata) > 0) {
    code = zar_metadata_from_list(metadata, &buffer, &error);
    if (code != NANOARROW_OK) {
      ArrowBufferReset(&buffer);
      return zar_failure_from_error(NULL, &error);
    }
  }

  /* No R allocation between here and the return that could longjmp over
     `buffer`: the owning pointer is made first. */
  SEXP out = PROTECT(zar_schema_owning_xptr());
  struct ArrowSchema *dst = (struct ArrowSchema *)R_ExternalPtrAddr(out);
  code = ArrowSchemaDeepCopy(schema, dst);
  if (code == NANOARROW_OK) {
    code = ArrowSchemaSetMetadata(
        dst, buffer.size_bytes > 0 ? (const char *)buffer.data : NULL);
  }
  ArrowBufferReset(&buffer);
  UNPROTECT(1);
  if (code != NANOARROW_OK) {
    return zar_failure(NULL, "the schema metadata could not be set");
  }
  return out;
}

/* ---- info --------------------------------------------------------------- */

SEXP zar_c_nanoarrow_version(void) {
  return Rf_mkString(ArrowNanoarrowVersion());
}

/* ---- array info, for printing ------------------------------------------ */

SEXP zar_c_array_info(SEXP x) {
  struct ArrowError error;
  struct ArrowArray *array = zar_array_from_xptr(x, &error);
  if (array == NULL) return zar_failure_from_error("handle", &error);
  const char *names[] = {"length", "null_count", "offset", "n_buffers",
                         "n_children", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, names));
  SET_VECTOR_ELT(out, 0, Rf_ScalarReal((double)array->length));
  SET_VECTOR_ELT(out, 1, Rf_ScalarReal((double)array->null_count));
  SET_VECTOR_ELT(out, 2, Rf_ScalarReal((double)array->offset));
  SET_VECTOR_ELT(out, 3, Rf_ScalarReal((double)array->n_buffers));
  SET_VECTOR_ELT(out, 4, Rf_ScalarReal((double)array->n_children));
  UNPROTECT(1);
  return out;
}

/* ---- reading a stream -------------------------------------------------- */

/* The next batch as an array handle whose tag is the stream's schema, or
   NULL once the stream has ended (section 6.1). The end is remembered on
   the handle, so a producer is never asked again after it said so. */
SEXP zar_c_stream_next(SEXP x) {
  struct ArrowError error;
  error.message[0] = '\0';
  SEXP ended_sym = Rf_install("zuarrow_ended");
  if (TYPEOF(x) == EXTPTRSXP && Rf_getAttrib(x, ended_sym) != R_NilValue) {
    return R_NilValue;
  }
  struct ArrowArrayStream *stream = zar_stream_from_xptr(x, &error);
  if (stream == NULL) return zar_failure_from_error("handle", &error);

  SEXP schema = PROTECT(zar_schema_copy_of(x));
  if (Rf_inherits(schema, "zar_failure")) {
    UNPROTECT(1);
    return schema;
  }
  SEXP out = PROTECT(zar_array_owning_xptr(schema));
  struct ArrowArray *array = (struct ArrowArray *)R_ExternalPtrAddr(out);
  int code = stream->get_next(stream, array);
  if (code != 0) {
    const char *msg = stream->get_last_error(stream);
    const char *kind = zar_reader_kind(stream);
    if (kind != NULL) {
      ArrowErrorSet(&error, "%s", msg == NULL ? strerror(code) : msg);
    } else {
      ArrowErrorSet(&error, "the next batch could not be read: %s",
                    msg == NULL ? strerror(code) : msg);
    }
    UNPROTECT(2);
    return zar_failure_from_error(kind == NULL ? "handle" : kind, &error);
  }
  if (array->release == NULL) {
    Rf_setAttrib(x, ended_sym, Rf_ScalarLogical(TRUE));
    UNPROTECT(2);
    return R_NilValue;
  }
  UNPROTECT(2);
  return out;
}

/* ---- a field of a struct array, for a registered handler -------------- */

/* A borrowed array: release only marks it released, because its buffers
   belong to the parent the handle keeps alive. */
static void zar_release_borrowed(struct ArrowArray *array) {
  array->release = NULL;
}

/* Field k of a struct array as its own array handle (section 6.10). The
   child is sliced by the parent's offset and length; the handle's
   protected field holds the parent, so the buffers outlive it. Null rows
   of the parent are not applied to the field. */
SEXP zar_c_array_child(SEXP x, SEXP r_k) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArray *array = zar_array_from_xptr(x, &error);
  if (array == NULL) return zar_failure_from_error("handle", &error);
  SEXP tag = zar_array_schema_xptr(x, &error);
  if (tag == NULL) return zar_failure_from_error("handle", &error);
  struct ArrowSchema *schema = zar_schema_from_xptr(tag, &error);
  int64_t k = (int64_t)Rf_asReal(r_k);
  if (k < 0 || k >= array->n_children || k >= schema->n_children) {
    return zar_failure("handle", "the array has no such field");
  }

  SEXP child_schema = PROTECT(zar_schema_owning_xptr());
  struct ArrowSchema *dst_schema =
      (struct ArrowSchema *)R_ExternalPtrAddr(child_schema);
  if (ArrowSchemaDeepCopy(schema->children[k], dst_schema) != NANOARROW_OK) {
    UNPROTECT(1);
    return zar_failure("handle", "the field's schema could not be copied");
  }
  SEXP out = PROTECT(zar_array_owning_xptr(child_schema));
  struct ArrowArray *dst = (struct ArrowArray *)R_ExternalPtrAddr(out);
  const struct ArrowArray *src = array->children[k];
  *dst = *src;
  dst->offset = src->offset + array->offset;
  dst->length = array->length;
  if (src->n_buffers > 0 && src->buffers[0] == NULL) {
    dst->null_count = 0;
  } else if (array->offset != 0 || array->length != src->length) {
    dst->null_count = -1;
  }
  dst->private_data = NULL;
  dst->release = &zar_release_borrowed;
  R_SetExternalPtrProtected(out, x);
  UNPROTECT(2);
  return out;
}
