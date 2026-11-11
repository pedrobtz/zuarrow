/* Internal constructors: an array from raw buffers, built without
   validation so tests can make malformed arrays on purpose, and a stream
   over arrays. Stage 3's conversion kernels are the public way to build
   arrays; these stay internal. */
#include <errno.h>
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
   is moved into the stream and left released. The stream holds the list,
   so a borrowed array's parent outlives it. */
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
  R_SetExternalPtrProtected(out, arrays);
  UNPROTECT(1);
  return out;
}

/* A stream from another producer whose get_next() always fails, or whose
   get_schema() does too, for the tests: any consumer reaches the branch a
   foreign producer's failure takes, without nanoarrow (#83, #110). */
static int zar_failing_get_schema(struct ArrowArrayStream *stream,
                                  struct ArrowSchema *out) {
  return ArrowSchemaDeepCopy((struct ArrowSchema *)stream->private_data, out);
}

static int zar_failing_get_schema_fails(struct ArrowArrayStream *stream,
                                        struct ArrowSchema *out) {
  (void)stream;
  out->release = NULL;
  return EIO;
}

static int zar_failing_get_next(struct ArrowArrayStream *stream,
                                struct ArrowArray *out) {
  (void)stream;
  out->release = NULL;
  return EIO;
}

static const char *zar_failing_get_last_error(
    struct ArrowArrayStream *stream) {
  (void)stream;
  return "the producer failed";
}

static void zar_failing_release(struct ArrowArrayStream *stream) {
  struct ArrowSchema *schema = (struct ArrowSchema *)stream->private_data;
  if (schema->release != NULL) schema->release(schema);
  ArrowFree(schema);
  stream->release = NULL;
}

SEXP zar_c_test_failing_stream(SEXP schema_xptr, SEXP schema_fails) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowSchema *schema = zar_schema_from_xptr(schema_xptr, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);
  SEXP out = PROTECT(zar_stream_owning_xptr());
  struct ArrowArrayStream *stream =
      (struct ArrowArrayStream *)R_ExternalPtrAddr(out);
  struct ArrowSchema *copy =
      (struct ArrowSchema *)ArrowMalloc(sizeof(struct ArrowSchema));
  if (copy == NULL || ArrowSchemaDeepCopy(schema, copy) != NANOARROW_OK) {
    ArrowFree(copy);
    UNPROTECT(1);
    return zar_failure(NULL, "the schema could not be copied");
  }
  stream->get_schema = Rf_asLogical(schema_fails) == TRUE
                           ? &zar_failing_get_schema_fails
                           : &zar_failing_get_schema;
  stream->get_next = &zar_failing_get_next;
  stream->get_last_error = &zar_failing_get_last_error;
  stream->release = &zar_failing_release;
  stream->private_data = copy;
  UNPROTECT(1);
  return out;
}

/* Releases a schema, array or stream handle in place, as another consumer
   or nanoarrow_pointer_release() would, so tests reach the released paths
   without nanoarrow (#106). The struct stays allocated, marked released.
   With `tag` true it releases the handle's tag instead: an array's own
   schema. */
SEXP zar_c_test_release(SEXP x, SEXP tag) {
  if (TYPEOF(x) == EXTPTRSXP && Rf_asLogical(tag) == TRUE) {
    x = R_ExternalPtrTag(x);
  }
  void *addr = TYPEOF(x) == EXTPTRSXP ? R_ExternalPtrAddr(x) : NULL;
  if (addr == NULL) return zar_failure("handle", "expected a live handle");
  if (Rf_inherits(x, "nanoarrow_schema")) {
    struct ArrowSchema *schema = (struct ArrowSchema *)addr;
    if (schema->release != NULL) schema->release(schema);
  } else if (Rf_inherits(x, "nanoarrow_array")) {
    struct ArrowArray *array = (struct ArrowArray *)addr;
    if (array->release != NULL) array->release(array);
  } else if (Rf_inherits(x, "nanoarrow_array_stream")) {
    struct ArrowArrayStream *stream = (struct ArrowArrayStream *)addr;
    if (stream->release != NULL) stream->release(stream);
  } else {
    return zar_failure("handle", "expected a schema, array or stream handle");
  }
  return R_NilValue;
}

/* Moves an array or stream out of handle `x`, as nanoarrow's
   nanoarrow_pointer_move() or a foreign consumer would, so tests reach
   the moved paths without nanoarrow. `into` is a released handle of the
   same kind, or NULL for a new handle, which holds nothing in its
   protected field: what the struct points into must be its own. Returns
   the handle moved into; `x` is left released. */
SEXP zar_c_test_move(SEXP x, SEXP into) {
  void *addr = TYPEOF(x) == EXTPTRSXP ? R_ExternalPtrAddr(x) : NULL;
  if (addr == NULL) return zar_failure("handle", "expected a live handle");
  int is_array = Rf_inherits(x, "nanoarrow_array");
  if (!is_array && !Rf_inherits(x, "nanoarrow_array_stream")) {
    return zar_failure("handle", "expected an array or stream handle");
  }
  SEXP out = into;
  if (into == R_NilValue) {
    if (is_array) {
      SEXP schema = PROTECT(zar_schema_copy_of(x));
      if (Rf_inherits(schema, "zar_failure")) {
        UNPROTECT(1);
        return schema;
      }
      out = zar_array_owning_xptr(schema);
      UNPROTECT(1);
    } else {
      out = zar_stream_owning_xptr();
    }
  }
  PROTECT(out);
  void *dst = TYPEOF(out) == EXTPTRSXP ? R_ExternalPtrAddr(out) : NULL;
  if (dst == NULL || Rf_inherits(out, "nanoarrow_array") != is_array) {
    UNPROTECT(1);
    return zar_failure("handle", "expected a handle of the same kind");
  }
  if (is_array) {
    struct ArrowArray *src = (struct ArrowArray *)addr;
    struct ArrowArray *a = (struct ArrowArray *)dst;
    if (src->release == NULL || a->release != NULL) {
      UNPROTECT(1);
      return zar_failure("handle", "expected a live source and a released target");
    }
    ArrowArrayMove(src, a);
  } else {
    struct ArrowArrayStream *src = (struct ArrowArrayStream *)addr;
    struct ArrowArrayStream *s = (struct ArrowArrayStream *)dst;
    if (src->release == NULL || s->release != NULL) {
      UNPROTECT(1);
      return zar_failure("handle", "expected a live source and a released target");
    }
    ArrowArrayStreamMove(src, s);
  }
  UNPROTECT(1);
  return out;
}

/* The inverse of zar_array_fill(): an array as the spec list(length,
   null_count, offset, buffers, children, dictionary), each buffer the raw
   bytes nanoarrow's view sizes it to, so tests can read the layout a
   registered handler receives (#171). */
static int64_t zar_view_buffer_size(const struct ArrowArrayView *view,
                                    int64_t i) {
  int32_t nv = view->n_variadic_buffers;
  if (view->storage_type == NANOARROW_TYPE_STRING_VIEW ||
      view->storage_type == NANOARROW_TYPE_BINARY_VIEW) {
    if (i < 2) return view->buffer_views[i].size_bytes;
    if (i < 2 + nv) return view->variadic_buffer_sizes[i - 2];
    return (int64_t)nv * (int64_t)sizeof(int64_t);
  }
  return i < NANOARROW_MAX_FIXED_BUFFERS ? view->buffer_views[i].size_bytes : 0;
}

static SEXP zar_view_to_spec(const struct ArrowArrayView *view) {
  const struct ArrowArray *array = view->array;
  const char *names[] = {"length",   "null_count", "offset", "buffers",
                         "children", "dictionary", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, names));
  SET_VECTOR_ELT(out, 0, Rf_ScalarReal((double)array->length));
  SET_VECTOR_ELT(out, 1, Rf_ScalarReal((double)array->null_count));
  SET_VECTOR_ELT(out, 2, Rf_ScalarReal((double)array->offset));
  SET_VECTOR_ELT(out, 3, Rf_allocVector(VECSXP, (R_xlen_t)array->n_buffers));
  SEXP buffers = VECTOR_ELT(out, 3);
  for (int64_t i = 0; i < array->n_buffers; i++) {
    if (array->buffers[i] == NULL) continue;
    int64_t size = zar_view_buffer_size(view, i);
    SET_VECTOR_ELT(buffers, (R_xlen_t)i,
                   Rf_allocVector(RAWSXP, (R_xlen_t)size));
    if (size > 0) {
      memcpy(RAW(VECTOR_ELT(buffers, (R_xlen_t)i)), array->buffers[i],
             (size_t)size);
    }
  }
  SET_VECTOR_ELT(out, 4,
                 Rf_allocVector(VECSXP, (R_xlen_t)array->n_children));
  SEXP children = VECTOR_ELT(out, 4);
  for (int64_t i = 0; i < array->n_children; i++) {
    SET_VECTOR_ELT(children, (R_xlen_t)i,
                   zar_view_to_spec(view->children[i]));
  }
  if (view->dictionary != NULL) {
    SET_VECTOR_ELT(out, 5, zar_view_to_spec(view->dictionary));
  }
  UNPROTECT(1);
  return out;
}

static SEXP zar_view_to_spec_call(void *data) {
  return zar_view_to_spec((const struct ArrowArrayView *)data);
}

static void zar_view_reset(void *data) {
  ArrowArrayViewReset((struct ArrowArrayView *)data);
}

SEXP zar_c_test_array_to_spec(SEXP x) {
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
  if (code == NANOARROW_OK) code = ArrowArrayViewSetArray(&view, array, &error);
  if (code != NANOARROW_OK) {
    ArrowArrayViewReset(&view);
    return zar_failure_from_error("format", &error);
  }
  /* The view is reset however the R allocations end, a longjmp included. */
  return R_ExecWithCleanup(zar_view_to_spec_call, &view, zar_view_reset,
                           &view);
}
