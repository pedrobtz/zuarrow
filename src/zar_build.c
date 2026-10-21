/* Internal constructors: an array from raw buffers, built without
   validation so tests can make malformed arrays on purpose, and a stream
   over arrays. Stage 3's conversion kernels are the public way to build
   arrays; these stay internal. */
#include <string.h>

#include "zar.h"

static SEXP zar_spec_get(SEXP list, const char *name) {
  SEXP names = Rf_getAttrib(list, R_NamesSymbol);
  if (TYPEOF(list) != VECSXP || TYPEOF(names) != STRSXP) return R_NilValue;
  for (R_xlen_t i = 0; i < Rf_xlength(list); i++) {
    if (strcmp(CHAR(STRING_ELT(names, i)), name) == 0) {
      return VECTOR_ELT(list, i);
    }
  }
  return R_NilValue;
}

static int64_t zar_spec_int(SEXP list, const char *name, int64_t dflt) {
  SEXP v = zar_spec_get(list, name);
  return v == R_NilValue ? dflt : (int64_t)Rf_asReal(v);
}

/* Fills an array nanoarrow initialised from its schema with the lengths
   and buffers in `spec`: list(length, null_count, offset, buffers,
   children, dictionary), buffers a list of raw vectors or NULLs. */
static int zar_array_fill(struct ArrowArray *array, SEXP spec,
                          struct ArrowError *error) {
  array->length = zar_spec_int(spec, "length", 0);
  array->null_count = zar_spec_int(spec, "null_count", 0);
  array->offset = zar_spec_int(spec, "offset", 0);

  SEXP buffers = zar_spec_get(spec, "buffers");
  R_xlen_t n = TYPEOF(buffers) == VECSXP ? Rf_xlength(buffers) : 0;
  for (R_xlen_t i = 0; i < n && i < array->n_buffers; i++) {
    SEXP raw = VECTOR_ELT(buffers, i);
    if (raw == R_NilValue) continue;
    if (TYPEOF(raw) != RAWSXP) {
      ArrowErrorSet(error, "buffers must be raw vectors or NULL");
      return EINVAL;
    }
    struct ArrowBuffer *buffer = ArrowArrayBuffer(array, (int64_t)i);
    if (ArrowBufferAppend(buffer, RAW(raw), (int64_t)Rf_xlength(raw)) !=
        NANOARROW_OK) {
      ArrowErrorSet(error, "cannot allocate a buffer");
      return ENOMEM;
    }
  }

  SEXP children = zar_spec_get(spec, "children");
  R_xlen_t n_children = TYPEOF(children) == VECSXP ? Rf_xlength(children) : 0;
  if (n_children != array->n_children) {
    ArrowErrorSet(error, "expected %ld children, got %ld",
                  (long)array->n_children, (long)n_children);
    return EINVAL;
  }
  for (R_xlen_t i = 0; i < n_children; i++) {
    int code = zar_array_fill(array->children[i], VECTOR_ELT(children, i),
                              error);
    if (code != NANOARROW_OK) return code;
  }

  SEXP dictionary = zar_spec_get(spec, "dictionary");
  if ((dictionary != R_NilValue) != (array->dictionary != NULL)) {
    ArrowErrorSet(error, "the dictionary does not match the schema");
    return EINVAL;
  }
  if (dictionary != R_NilValue) {
    return zar_array_fill(array->dictionary, dictionary, error);
  }
  return NANOARROW_OK;
}

SEXP zar_c_array_from_buffers(SEXP schema_xptr, SEXP spec) {
  struct ArrowError error;
  error.message[0] = '\0';
  SEXP schema_copy = PROTECT(zar_schema_copy_of(schema_xptr));
  if (Rf_inherits(schema_copy, "zar_failure")) {
    UNPROTECT(1);
    return schema_copy;
  }
  struct ArrowSchema *schema =
      (struct ArrowSchema *)R_ExternalPtrAddr(schema_copy);
  SEXP out = PROTECT(zar_array_owning_xptr(schema_copy));
  struct ArrowArray *array = (struct ArrowArray *)R_ExternalPtrAddr(out);
  int code = ArrowArrayInitFromSchema(array, schema, &error);
  if (code == NANOARROW_OK) code = zar_array_fill(array, spec, &error);
  if (code == NANOARROW_OK) {
    code = ArrowArrayFinishBuilding(array, NANOARROW_VALIDATION_LEVEL_NONE,
                                    &error);
  }
  UNPROTECT(2);
  if (code != NANOARROW_OK) return zar_failure_from_error(NULL, &error);
  return out;
}

/* A stream over `arrays`, which it takes ownership of: each array handle
   is moved into the stream and left released. */
SEXP zar_c_stream_from_arrays(SEXP schema_xptr, SEXP arrays) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowSchema *schema = zar_schema_from_xptr(schema_xptr, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);
  R_xlen_t n = Rf_xlength(arrays);
  for (R_xlen_t i = 0; i < n; i++) {
    if (zar_array_from_xptr(VECTOR_ELT(arrays, i), &error) == NULL) {
      return zar_failure_from_error("handle", &error);
    }
  }

  SEXP out = PROTECT(zar_stream_owning_xptr());
  struct ArrowArrayStream *stream =
      (struct ArrowArrayStream *)R_ExternalPtrAddr(out);
  struct ArrowSchema copy;
  if (ArrowSchemaDeepCopy(schema, &copy) != NANOARROW_OK) {
    UNPROTECT(1);
    return zar_failure(NULL, "the schema could not be copied");
  }
  /* The stream takes ownership of `copy`, and frees it if init fails. */
  if (ArrowBasicArrayStreamInit(stream, &copy, (int64_t)n) != NANOARROW_OK) {
    if (copy.release != NULL) copy.release(&copy);
    UNPROTECT(1);
    return zar_failure(NULL, "the stream could not be allocated");
  }
  for (R_xlen_t i = 0; i < n; i++) {
    struct ArrowArray *array =
        (struct ArrowArray *)R_ExternalPtrAddr(VECTOR_ELT(arrays, i));
    ArrowBasicArrayStreamSetArray(stream, (int64_t)i, array);
  }
  UNPROTECT(1);
  return out;
}
