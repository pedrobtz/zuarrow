/* Handles: external pointers in nanoarrow's r.h layout (design D6, D7,
   section 6.1), the failure objects C returns to R, and the schema tools
   that need nothing beyond a schema: copy, printing and the spec round
   trip the R layer builds schemas through. */
#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include <R_ext/Riconv.h>

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

/* A native string's bytes in UTF-8, converted strictly from the session's
   encoding: translateCharUTF8() would write a byte it cannot convert as
   "<xx>" text, as it does for every non-ASCII byte in a C locale (#203).
   NULL when any byte does not convert. The buffer is R_alloc()ed. */
static const char *zar_native_utf8(SEXP s, size_t *len) {
  void *cd = Riconv_open("UTF-8", "");
  if (cd == (void *)-1) return NULL;
  const char *in = CHAR(s);
  size_t in_left = (size_t)LENGTH(s);
  /* A character of any encoding R supports takes at most 4 UTF-8 bytes,
     and never fewer bytes in the source. */
  size_t cap = 4 * in_left + 1;
  char *buf = R_alloc(cap, 1);
  char *out = buf;
  size_t out_left = cap - 1;
  size_t done = Riconv(cd, &in, &in_left, &out, &out_left);
  if (done == 0 && in_left == 0) {
    done = Riconv(cd, NULL, NULL, &out, &out_left);
  }
  Riconv_close(cd);
  /* Anything but a clean, reversible conversion of every byte fails. */
  if (done != 0 || in_left != 0) return NULL;
  *out = '\0';
  *len = (size_t)(out - buf);
  if (zar_utf8_invalid_at((const uint8_t *)buf, (int64_t)*len) >= 0) {
    return NULL;
  }
  return buf;
}

/* A string's UTF-8 bytes, or NULL when it has none exactly.
   translateCharUTF8() returns the CHARSXP's own bytes when no translation
   is needed (UTF-8, ASCII, or native in a UTF-8 session); then its length
   is known without a strlen(), and the bytes are checked. A latin1 string
   translates exactly. A native string that needs translating is converted
   strictly, never escaped. A "bytes" string is refused before
   translateCharUTF8() can raise on it. */
const char *zar_char_utf8(SEXP s, size_t *len) {
  cetype_t ce = Rf_getCharCE(s);
  if (ce == CE_BYTES) return NULL;
  const char *u = Rf_translateCharUTF8(s);
  if (u == CHAR(s)) {
    *len = (size_t)LENGTH(s);
    if (zar_utf8_invalid_at((const uint8_t *)u, (int64_t)*len) >= 0) {
      return NULL;
    }
  } else if (ce == CE_NATIVE) {
    return zar_native_utf8(s, len);
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

/* Raises the bare zuarrow_error of a failed allocation (design section 8,
   #233). The owning constructors below have no handle yet to return a
   failure through, so they raise, as Rf_error() did, but with the class
   every other allocation failure has. Nothing native is owned here yet. */
NORET static void zar_alloc_abort(const char *message) {
  SEXP cond = PROTECT(Rf_allocVector(VECSXP, 2));
  SEXP names = PROTECT(Rf_allocVector(STRSXP, 2));
  SET_STRING_ELT(names, 0, Rf_mkChar("message"));
  SET_STRING_ELT(names, 1, Rf_mkChar("call"));
  Rf_setAttrib(cond, R_NamesSymbol, names);
  SET_VECTOR_ELT(cond, 0, Rf_mkString(message));
  SEXP cls = PROTECT(Rf_allocVector(STRSXP, 3));
  SET_STRING_ELT(cls, 0, Rf_mkChar("zuarrow_error"));
  SET_STRING_ELT(cls, 1, Rf_mkChar("error"));
  SET_STRING_ELT(cls, 2, Rf_mkChar("condition"));
  Rf_setAttrib(cond, R_ClassSymbol, cls);
  SEXP expr = PROTECT(Rf_lang2(Rf_install("stop"), cond));
  Rf_eval(expr, R_BaseEnv);
  /* Not reached, as stop() does not return; Rf_error() keeps it so. */
  Rf_error("%s", message);
}

/* The struct is allocated before the external pointer so that a failed
   R allocation cannot leak it: R_MakeExternalPtr is the only call that can
   longjmp between malloc() and the finalizer taking ownership, and the
   finalizer is registered on the very next line. */
SEXP zar_schema_owning_xptr(void) {
  struct ArrowSchema *schema =
      (struct ArrowSchema *)malloc(sizeof(struct ArrowSchema));
  if (schema == NULL) {
    zar_alloc_abort("cannot allocate an ArrowSchema");
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
    zar_alloc_abort("cannot allocate an ArrowArray");
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
    zar_alloc_abort("cannot allocate an ArrowArrayStream");
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

/* A child lent by zar_c_array_child(): release only marks it released,
   because its buffers belong to the parent its handle's protected field
   holds. */
static void zar_release_lent(struct ArrowArray *array) {
  array->release = NULL;
}

/* Whether the array behind handle `x` can be read: it is live, and so is
   every parent it was lent by. A lent child's own release is never seen
   when its parent is released, so the parents are checked too (#205). */
static int zar_array_xptr_live(SEXP x) {
  for (;;) {
    struct ArrowArray *array =
        TYPEOF(x) == EXTPTRSXP ? (struct ArrowArray *)R_ExternalPtrAddr(x) : NULL;
    if (array == NULL || array->release == NULL) return 0;
    if (array->release != &zar_release_lent) return 1;
    x = R_ExternalPtrProtected(x);
  }
}

struct ArrowArray *zar_array_from_xptr(SEXP x, struct ArrowError *error) {
  struct ArrowArray *array = (struct ArrowArray *)zar_xptr_addr(
      x, "nanoarrow_array", "an array", error);
  if (array != NULL && !zar_array_xptr_live(x)) {
    ArrowErrorSet(error, array->release == NULL
                             ? "the array handle has been released"
                             : "the array this field was lent by has been released");
    return NULL;
  }
  return array;
}

int zar_array_handle_live(SEXP x) { return zar_array_xptr_live(x); }

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
                    msg == NULL || msg[0] == '\0' ? strerror(code) : msg);
      UNPROTECT(1);
      return zar_failure_from_error(zar_code_kind(code, "handle"), &error);
    }
    UNPROTECT(1);
    return out;
  } else {
    ArrowErrorSet(&error, "expected a schema, array or stream handle");
  }

  if (src == NULL) return zar_failure_from_error("handle", &error);

  SEXP out = PROTECT(zar_schema_owning_xptr());
  struct ArrowSchema *dst = (struct ArrowSchema *)R_ExternalPtrAddr(out);
  int code = ArrowSchemaDeepCopy(src, dst);
  if (code != NANOARROW_OK) {
    UNPROTECT(1);
    return zar_failure(zar_code_kind(code, "handle"), "the schema could not be copied");
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
  // Translate every key before the builder owns memory: a translation that
  // longjmps then leaves nothing to free (R_alloc is reclaimed by R).
  struct ArrowStringView *keys =
      n > 0 ? (struct ArrowStringView *)R_alloc((size_t)n, sizeof(*keys))
            : NULL;
  for (R_xlen_t i = 0; i < n; i++) {
    if (TYPEOF(VECTOR_ELT(metadata, i)) != RAWSXP) {
      ArrowErrorSet(error, "metadata values must be raw vectors");
      return EINVAL;
    }
    size_t key_len;
    const char *key = zar_char_utf8(STRING_ELT(names, i), &key_len);
    if (key == NULL) {
      ArrowErrorSet(error, "a metadata key is not valid UTF-8");
      return EILSEQ;
    }
    keys[i].data = key;
    keys[i].size_bytes = (int64_t)key_len;
  }
  if (ArrowMetadataBuilderInit(out, NULL) != NANOARROW_OK) {
    ArrowErrorSet(error, "cannot allocate metadata");
    return ENOMEM;
  }
  for (R_xlen_t i = 0; i < n; i++) {
    SEXP value = VECTOR_ELT(metadata, i);
    struct ArrowStringView v = {(const char *)RAW(value),
                                (int64_t)Rf_xlength(value)};
    if (ArrowMetadataBuilderAppend(out, keys[i], v) != NANOARROW_OK) {
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
    ArrowBufferInit(&buffer);
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
    /* A spec that cannot become a schema: a missing format, a string that
       is not UTF-8, metadata that is not a named list of raw vectors. */
    return zar_failure_from_error(zar_code_kind(code, "type"), &error);
  }
  return out;
}

/* Metadata as a named list of raw values. Its keys must have passed
   zar_metadata_check_keys(): a key with a NUL cannot become an R string,
   so each entry point that reaches here refuses one first. */
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
  if (zar_schema_check_text(schema, &error) != NANOARROW_OK) {
    return zar_failure_from_error("format", &error);
  }
  return zar_schema_spec(schema);
}

/* ---- metadata ----------------------------------------------------------- */

SEXP zar_c_schema_metadata(SEXP x) {
  struct ArrowError error;
  struct ArrowSchema *schema = zar_schema_from_xptr(x, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);
  if (zar_metadata_check_keys(schema->metadata, &error) != NANOARROW_OK) {
    return zar_failure_from_error("format", &error);
  }
  return zar_metadata_to_list(schema->metadata);
}

SEXP zar_c_schema_with_metadata(SEXP x, SEXP metadata) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowSchema *schema = zar_schema_from_xptr(x, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);

  /* Make the owning pointer and translate the keys before `buffer` holds
     memory, so no R allocation can longjmp over it. */
  SEXP out = PROTECT(zar_schema_owning_xptr());
  struct ArrowSchema *dst = (struct ArrowSchema *)R_ExternalPtrAddr(out);
  struct ArrowBuffer buffer;
  ArrowBufferInit(&buffer);
  int code = NANOARROW_OK;
  if (metadata != R_NilValue && Rf_xlength(metadata) > 0) {
    code = zar_metadata_from_list(metadata, &buffer, &error);
    if (code != NANOARROW_OK) {
      ArrowBufferReset(&buffer);
      UNPROTECT(1);
      return zar_failure_from_error(code == ENOMEM ? NULL : "type", &error);
    }
  }

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

/* A stream that has ended, wrapped so it answers every later get_next()
   with the end itself and never asks its producer again (section 6.1).
   The mark is the stream's own state, not its R handle's, so it moves
   with the struct, and a live stream moved into the handle replaces it
   (#220). Release never calls R. */
static int zar_ended_get_schema(struct ArrowArrayStream *stream,
                                struct ArrowSchema *out) {
  struct ArrowArrayStream *inner = (struct ArrowArrayStream *)stream->private_data;
  return inner->get_schema(inner, out);
}

static int zar_ended_get_next(struct ArrowArrayStream *stream,
                              struct ArrowArray *out) {
  (void)stream;
  out->release = NULL;
  return NANOARROW_OK;
}

static const char *zar_ended_last_error(struct ArrowArrayStream *stream) {
  (void)stream;
  return NULL;
}

static void zar_ended_release(struct ArrowArrayStream *stream) {
  struct ArrowArrayStream *inner = (struct ArrowArrayStream *)stream->private_data;
  if (inner->release != NULL) inner->release(inner);
  free(inner);
  stream->private_data = NULL;
  stream->release = NULL;
}

/* Marks `stream` ended in place. Without memory it stays unmarked, and
   its producer is asked again. */
static void zar_mark_ended(struct ArrowArrayStream *stream) {
  if (stream->get_next == &zar_ended_get_next) return;
  struct ArrowArrayStream *inner =
      (struct ArrowArrayStream *)malloc(sizeof(struct ArrowArrayStream));
  if (inner == NULL) return;
  ArrowArrayStreamMove(stream, inner);
  stream->get_schema = &zar_ended_get_schema;
  stream->get_next = &zar_ended_get_next;
  stream->get_last_error = &zar_ended_last_error;
  stream->release = &zar_ended_release;
  stream->private_data = inner;
}

/* The next batch as an array handle whose tag is the stream's schema, or
   NULL once the stream has ended (section 6.1). */
SEXP zar_c_stream_next(SEXP x) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArrayStream *stream = zar_stream_from_xptr(x, &error);
  if (stream == NULL) return zar_failure_from_error("handle", &error);
  if (stream->get_next == &zar_ended_get_next) return R_NilValue;

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
    if (msg == NULL || msg[0] == '\0') msg = strerror(code);
    const char *kind = zar_reader_kind(stream);
    if (kind != NULL) {
      ArrowErrorSet(&error, "%s", msg);
    } else {
      ArrowErrorSet(&error, "the next batch could not be read: %s", msg);
    }
    UNPROTECT(2);
    return zar_failure_from_error(zar_code_kind(code, kind == NULL ? "handle" : kind),
                                  &error);
  }
  if (array->release == NULL) {
    zar_mark_ended(stream);
    UNPROTECT(2);
    return R_NilValue;
  }
  UNPROTECT(2);
  return out;
}

/* ---- a field of a struct array, for a registered handler -------------- */

/* Copies every buffer of the array `view` sees into `dst`, which
   ArrowArrayInitFromSchema() made from the same schema, and its children
   and dictionary the same way. Offsets, lengths and null counts are kept,
   so the copy reads as the source does. */
static int zar_copy_buffers(const struct ArrowArrayView *view,
                            struct ArrowArray *dst) {
  dst->length = view->length;
  dst->offset = view->offset;
  dst->null_count = view->null_count;
  int code = NANOARROW_OK;
  for (int i = 0; code == NANOARROW_OK && i < NANOARROW_MAX_FIXED_BUFFERS; i++) {
    enum ArrowBufferType type = view->layout.buffer_type[i];
    if (type == NANOARROW_BUFFER_TYPE_NONE ||
        type == NANOARROW_BUFFER_TYPE_VARIADIC_DATA ||
        type == NANOARROW_BUFFER_TYPE_VARIADIC_SIZE) {
      continue;
    }
    const struct ArrowBufferView *b = &view->buffer_views[i];
    if (b->data.data != NULL && b->size_bytes > 0) {
      code = ArrowBufferAppend(ArrowArrayBuffer(dst, i), b->data.data, b->size_bytes);
    }
  }
  if (code == NANOARROW_OK && view->n_variadic_buffers > 0) {
    code = ArrowArrayAddVariadicBuffers(dst, view->n_variadic_buffers);
    for (int32_t i = 0; code == NANOARROW_OK && i < view->n_variadic_buffers; i++) {
      if (view->variadic_buffer_sizes[i] > 0) {
        code = ArrowBufferAppend(ArrowArrayBuffer(dst, NANOARROW_BINARY_VIEW_FIXED_BUFFERS + i),
                                 view->variadic_buffers[i],
                                 view->variadic_buffer_sizes[i]);
      }
    }
  }
  for (int64_t k = 0; code == NANOARROW_OK && k < view->n_children; k++) {
    code = zar_copy_buffers(view->children[k], dst->children[k]);
  }
  if (code == NANOARROW_OK && view->dictionary != NULL) {
    code = zar_copy_buffers(view->dictionary, dst->dictionary);
  }
  return code;
}

/* An array handle over a copy of `x`, for a consumer that moves the array
   it is given, such as a stream: releasing it leaves `x` alone. It owns
   every byte it points into, so it outlives `x` and any R object, and a
   foreign consumer can move it out and release it on any thread without
   R (#204). A shallow borrow would keep `x` alive only through the R
   handle's protected field, which a moved struct leaves behind. */
SEXP zar_c_array_borrow(SEXP x) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArray *array = zar_array_from_xptr(x, &error);
  if (array == NULL) return zar_failure_from_error("handle", &error);
  SEXP tag = zar_array_schema_xptr(x, &error);
  if (tag == NULL) return zar_failure_from_error("handle", &error);
  struct ArrowSchema *schema = zar_schema_from_xptr(tag, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);

  SEXP out = PROTECT(zar_array_owning_xptr(tag));
  struct ArrowArray *dst = (struct ArrowArray *)R_ExternalPtrAddr(out);
  struct ArrowArrayView view;
  int code = ArrowArrayViewInitFromSchema(&view, schema, &error);
  if (code == NANOARROW_OK) code = ArrowArrayViewSetArray(&view, array, &error);
  if (code == NANOARROW_OK) code = ArrowArrayInitFromSchema(dst, schema, &error);
  if (code == NANOARROW_OK) code = zar_copy_buffers(&view, dst);
  if (code == NANOARROW_OK) {
    code = ArrowArrayFinishBuildingDefault(dst, &error);
  }
  ArrowArrayViewReset(&view);
  UNPROTECT(1);
  if (code != NANOARROW_OK) {
    /* The handle's finalizer releases a partly built copy. */
    return zar_failure(code == ENOMEM ? NULL : "format",
                       "the array could not be copied");
  }
  return out;
}

/* The values of a dictionary or run-end encoded array, one per row, as a
   plain array of the value type (section 6.10). A registered handler for
   the value type receives this array, never the indices or the run ends.
   The schema is the value type's, named and annotated as the encoded
   field is. Fixed-width values and binary or string values are copied;
   any other value layout is a type failure. */
SEXP zar_c_array_decode(SEXP x) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArray *array = zar_array_from_xptr(x, &error);
  if (array == NULL) return zar_failure_from_error("handle", &error);
  SEXP tag = zar_array_schema_xptr(x, &error);
  if (tag == NULL) return zar_failure_from_error("handle", &error);
  struct ArrowSchema *schema = zar_schema_from_xptr(tag, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);

  struct ArrowArrayView view;
  int code = ArrowArrayViewInitFromSchema(&view, schema, &error);
  if (code != NANOARROW_OK) {
    return zar_failure_from_error(zar_code_kind(code, "format"), &error);
  }
  /* The values are copied below: check every offset and range first. */
  code = ArrowArrayViewSetArray(&view, array, &error);
  if (code == NANOARROW_OK) code = zar_view_check_read(&view, &error);
  if (code != NANOARROW_OK) {
    ArrowArrayViewReset(&view);
    return zar_failure_from_error(zar_code_kind(code, "format"), &error);
  }
  int ree =view.storage_type == NANOARROW_TYPE_RUN_END_ENCODED;
  if (schema->dictionary == NULL && !ree) {
    ArrowArrayViewReset(&view);
    return zar_failure("handle",
                       "the array is not dictionary or run-end encoded");
  }
  struct ArrowSchema *value_schema =
      ree ? schema->children[1] : schema->dictionary;
  struct ArrowArrayView *values = ree ? view.children[1] : view.dictionary;
  struct ArrowArrayView *ends = ree ? view.children[0] : NULL;

  int64_t bits = values->layout.element_size_bits[1];
  int fixed = value_schema->dictionary == NULL &&
              value_schema->n_children == 0 &&
              values->layout.buffer_type[0] == NANOARROW_BUFFER_TYPE_VALIDITY &&
              values->layout.buffer_type[1] == NANOARROW_BUFFER_TYPE_DATA &&
              values->layout.buffer_type[2] == NANOARROW_BUFFER_TYPE_NONE &&
              (bits == 1 || (bits > 0 && bits % 8 == 0));
  int bytes = value_schema->dictionary == NULL &&
              (values->storage_type == NANOARROW_TYPE_STRING ||
               values->storage_type == NANOARROW_TYPE_LARGE_STRING ||
               values->storage_type == NANOARROW_TYPE_BINARY ||
               values->storage_type == NANOARROW_TYPE_LARGE_BINARY);
  if (!fixed && !bytes) {
    ArrowArrayViewReset(&view);
    return zar_failure(
        "type",
        "a registered handler can't read this column: its encoded values "
        "are not of a fixed width, binary or string");
  }

  SEXP out_schema = PROTECT(zar_schema_owning_xptr());
  struct ArrowSchema *dst_schema =
      (struct ArrowSchema *)R_ExternalPtrAddr(out_schema);
  code = ArrowSchemaDeepCopy(value_schema, dst_schema);
  if (code == NANOARROW_OK) code = ArrowSchemaSetName(dst_schema, schema->name);
  if (code == NANOARROW_OK && schema->metadata != NULL) {
    code = ArrowSchemaSetMetadata(dst_schema, schema->metadata);
  }
  if (code != NANOARROW_OK) {
    ArrowArrayViewReset(&view);
    UNPROTECT(1);
    return zar_failure(zar_code_kind(code, "handle"), "the value schema could not be copied");
  }
  SEXP out = PROTECT(zar_array_owning_xptr(out_schema));
  struct ArrowArray *dst = (struct ArrowArray *)R_ExternalPtrAddr(out);
  code = ArrowArrayInitFromSchema(dst, dst_schema, &error);
  if (code != NANOARROW_OK) {
    ArrowArrayViewReset(&view);
    UNPROTECT(2);
    return zar_failure_from_error(zar_code_kind(code, "format"), &error);
  }

  int64_t n = array->length;
  int64_t run = 0;
  int64_t nulls = 0;
  struct ArrowBitmap *bitmap = ArrowArrayValidityBitmap(dst);
  struct ArrowBuffer *data = ArrowArrayBuffer(dst, 1);
  if (fixed) {
    code = ArrowBitmapReserve(bitmap, n);
    if (code == NANOARROW_OK) {
      code = bits == 1 ? ArrowBufferAppendFill(data, 0, (n + 7) / 8)
                       : ArrowBufferAppendFill(data, 0, n * (bits / 8));
    }
  } else {
    code = ArrowArrayStartAppending(dst);
  }
  const char *failure = NULL;
  for (int64_t i = 0; code == NANOARROW_OK && i < n; i++) {
    int64_t j;
    if (ree) {
      /* Run ends are strictly increasing and validated above. */
      int64_t logical = view.offset + i;
      while (run < ends->length &&
             ArrowArrayViewGetIntUnsafe(ends, run) <= logical) {
        run++;
      }
      if (run >= ends->length) {
        failure = "a run-end encoding ends before its last row";
        break;
      }
      j = run;
    } else if (ArrowArrayViewIsNull(&view, i)) {
      j = -1;
    } else {
      j = ArrowArrayViewGetIntUnsafe(&view, i);
      if (j < 0 || j >= values->length) {
        failure = "a dictionary index is outside its dictionary";
        break;
      }
    }
    int valid = j >= 0 && !ArrowArrayViewIsNull(values, j);
    nulls += !valid;
    if (fixed) {
      ArrowBitmapAppendUnsafe(bitmap, (uint8_t)valid, 1);
      if (!valid) continue;
      const uint8_t *src = values->buffer_views[1].data.as_uint8;
      int64_t at = values->offset + j;
      if (bits == 1) {
        ArrowBitSetTo(data->data, i, ArrowBitGet(src, at));
      } else {
        int64_t width = bits / 8;
        memcpy(data->data + i * width, src + at * width, (size_t)width);
      }
    } else if (!valid) {
      code = ArrowArrayAppendNull(dst, 1);
    } else {
      struct ArrowBufferView value = ArrowArrayViewGetBytesUnsafe(values, j);
      code = ArrowArrayAppendBytes(dst, value);
    }
  }
  ArrowArrayViewReset(&view);
  if (failure != NULL) {
    UNPROTECT(2);
    return zar_failure("format", failure);
  }
  if (fixed && code == NANOARROW_OK) {
    dst->length = n;
    dst->null_count = nulls;
    if (nulls == 0) ArrowBitmapReset(bitmap);
  }
  if (code == NANOARROW_OK) code = ArrowArrayFinishBuildingDefault(dst, &error);
  UNPROTECT(2);
  if (code != NANOARROW_OK) {
    return zar_failure(zar_code_kind(code, "format"), "the encoded values could not be copied");
  }
  return out;
}

/* Which rows of an array are null by its own validity bitmap, as a
   logical vector; NULL when it has no bitmap. Registered handlers get a
   struct's fields through zar_c_array_child(), which leaves the struct's
   null rows to R. */
SEXP zar_c_array_nulls(SEXP x) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArray *array = zar_array_from_xptr(x, &error);
  if (array == NULL) return zar_failure_from_error("handle", &error);
  if (array->n_buffers == 0 || array->buffers[0] == NULL ||
      array->null_count == 0) {
    return R_NilValue;
  }
  if (array->length > R_XLEN_T_MAX) {
    return zar_failure("limit", "the array holds more rows than R allows");
  }
  const uint8_t *bits = (const uint8_t *)array->buffers[0];
  SEXP out = PROTECT(Rf_allocVector(LGLSXP, (R_xlen_t)array->length));
  int *dst = LOGICAL(out);
  for (int64_t i = 0; i < array->length; i++) {
    dst[i] = !ArrowBitGet(bits, array->offset + i);
  }
  UNPROTECT(1);
  return out;
}

/* Field k of a struct array as its own array handle (section 6.10). The
   child is sliced by the parent's offset and length; the handle's
   protected field holds the parent, so the buffers outlive it, and every
   reader of the handle checks the parent is still live, so a released
   parent is a handle error, not a read of freed memory (#205). Null rows
   of the parent are not applied to the field. The child is lent: a
   consumer that moves it out of its handle gets no owner with it. */
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
  /* A union has no validity bitmap, so its null count is always 0: its
     first buffer is the type ids (#171). */
  const char *format = schema->children[k]->format;
  int is_union = format != NULL && strncmp(format, "+u", 2) == 0;
  if (is_union || (src->n_buffers > 0 && src->buffers[0] == NULL)) {
    dst->null_count = 0;
  } else if (array->offset != 0 || array->length != src->length) {
    dst->null_count = -1;
  }
  dst->private_data = NULL;
  dst->release = &zar_release_lent;
  R_SetExternalPtrProtected(out, x);
  UNPROTECT(2);
  return out;
}
