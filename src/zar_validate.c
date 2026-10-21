/* arrow_validate() and arrow_equal() (design section 6.11): nanoarrow's
   validation levels and array comparison, reached from R. */
#include <string.h>

#include "zar.h"

static enum ArrowValidationLevel zar_level(SEXP level) {
  switch (Rf_asInteger(level)) {
    case 1:
      return NANOARROW_VALIDATION_LEVEL_MINIMAL;
    case 2:
      return NANOARROW_VALIDATION_LEVEL_DEFAULT;
    default:
      return NANOARROW_VALIDATION_LEVEL_FULL;
  }
}

/* Validates `array` against `schema` at `level` into `view`, which the
   caller has initialised from the schema and resets. */
static int zar_view_set(struct ArrowArrayView *view, const struct ArrowArray *array,
                        enum ArrowValidationLevel level,
                        struct ArrowError *error) {
  if (level == NANOARROW_VALIDATION_LEVEL_MINIMAL) {
    return ArrowArrayViewSetArrayMinimal(view, array, error);
  }
  int code = ArrowArrayViewSetArray(view, array, error);
  if (code != NANOARROW_OK || level != NANOARROW_VALIDATION_LEVEL_FULL) {
    return code;
  }
  code = ArrowArrayViewValidate(view, NANOARROW_VALIDATION_LEVEL_FULL, error);
  if (code != NANOARROW_OK) return code;
  return zar_view_validate_utf8(view, "", error);
}

SEXP zar_c_array_validate(SEXP x, SEXP level) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArray *array = zar_array_from_xptr(x, &error);
  if (array == NULL) return zar_failure_from_error("handle", &error);
  SEXP schema_xptr = zar_array_schema_xptr(x, &error);
  if (schema_xptr == NULL) return zar_failure_from_error("handle", &error);
  struct ArrowSchema *schema = zar_schema_from_xptr(schema_xptr, &error);

  struct ArrowArrayView view;
  int code = ArrowArrayViewInitFromSchema(&view, schema, &error);
  if (code == NANOARROW_OK) {
    code = zar_view_set(&view, array, zar_level(level), &error);
  }
  ArrowArrayViewReset(&view);
  if (code != NANOARROW_OK) return zar_failure_from_error("format", &error);
  return Rf_ScalarLogical(TRUE);
}

/* Reads every batch of a stream, validating each, and releases them. The
   stream is consumed, as reading any stream consumes it. */
SEXP zar_c_stream_validate(SEXP x, SEXP level) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArrayStream *stream = zar_stream_from_xptr(x, &error);
  if (stream == NULL) return zar_failure_from_error("handle", &error);

  struct ArrowSchema schema;
  schema.release = NULL;
  int code = stream->get_schema(stream, &schema);
  if (code != 0) {
    const char *msg = stream->get_last_error(stream);
    ArrowErrorSet(&error, "the stream could not report its schema: %s",
                  msg == NULL ? strerror(code) : msg);
    return zar_failure_from_error("handle", &error);
  }

  struct ArrowArrayView view;
  code = ArrowArrayViewInitFromSchema(&view, &schema, &error);
  const char *kind = "format";
  enum ArrowValidationLevel lvl = zar_level(level);
  for (long batch = 0; code == NANOARROW_OK; batch++) {
    struct ArrowArray array;
    array.release = NULL;
    code = stream->get_next(stream, &array);
    if (code != 0) {
      const char *msg = stream->get_last_error(stream);
      ArrowErrorSet(&error, "batch %ld could not be read: %s", batch,
                    msg == NULL ? strerror(code) : msg);
      kind = "handle";
      break;
    }
    if (array.release == NULL) break;
    struct ArrowError inner;
    inner.message[0] = '\0';
    code = zar_view_set(&view, &array, lvl, &inner);
    array.release(&array);
    if (code != NANOARROW_OK) {
      ArrowErrorSet(&error, "batch %ld: %s", batch, inner.message);
    }
  }
  ArrowArrayViewReset(&view);
  schema.release(&schema);
  if (code != NANOARROW_OK) return zar_failure_from_error(kind, &error);
  return Rf_ScalarLogical(TRUE);
}

/* ---- equality ----------------------------------------------------------- */

static int zar_str_equal(const char *a, const char *b) {
  if (a == NULL || b == NULL) return a == b;
  return strcmp(a, b) == 0;
}

static int zar_metadata_equal(const char *a, const char *b) {
  int64_t na = a == NULL ? 0 : ArrowMetadataSizeOf(a);
  int64_t nb = b == NULL ? 0 : ArrowMetadataSizeOf(b);
  /* Absent metadata and an empty key list are the same thing. */
  if (na <= 4 && nb <= 4) return 1;
  return na == nb && memcmp(a, b, (size_t)na) == 0;
}

/* 1 when equal; 0 with `reason` set otherwise. `path` names the node. */
static int zar_schema_equal(const struct ArrowSchema *x,
                            const struct ArrowSchema *y, int metadata,
                            const char *path, struct ArrowError *reason) {
  if (!zar_str_equal(x->format, y->format)) {
    ArrowErrorSet(reason, "%sformat '%s' differs from '%s'", path,
                  x->format == NULL ? "" : x->format,
                  y->format == NULL ? "" : y->format);
    return 0;
  }
  if (!zar_str_equal(x->name, y->name)) {
    ArrowErrorSet(reason, "%sname '%s' differs from '%s'", path,
                  x->name == NULL ? "" : x->name,
                  y->name == NULL ? "" : y->name);
    return 0;
  }
  if (x->flags != y->flags) {
    ArrowErrorSet(reason, "%sflags %ld differ from %ld", path, (long)x->flags,
                  (long)y->flags);
    return 0;
  }
  if (metadata && !zar_metadata_equal(x->metadata, y->metadata)) {
    ArrowErrorSet(reason, "%smetadata differs", path);
    return 0;
  }
  if (x->n_children != y->n_children) {
    ArrowErrorSet(reason, "%s%ld children differ from %ld", path,
                  (long)x->n_children, (long)y->n_children);
    return 0;
  }
  char child_path[256];
  for (int64_t i = 0; i < x->n_children; i++) {
    snprintf(child_path, sizeof(child_path), "%schild %ld: ", path, (long)i);
    if (!zar_schema_equal(x->children[i], y->children[i], metadata, child_path,
                          reason)) {
      return 0;
    }
  }
  if ((x->dictionary == NULL) != (y->dictionary == NULL)) {
    ArrowErrorSet(reason, "%sonly one side has a dictionary", path);
    return 0;
  }
  if (x->dictionary != NULL) {
    snprintf(child_path, sizeof(child_path), "%sdictionary: ", path);
    return zar_schema_equal(x->dictionary, y->dictionary, metadata, child_path,
                            reason);
  }
  return 1;
}

static SEXP zar_equal_result(int equal, const char *reason) {
  SEXP out = PROTECT(Rf_ScalarLogical(equal ? TRUE : FALSE));
  if (!equal) {
    SEXP why = PROTECT(zar_scalar_utf8(reason));
    Rf_setAttrib(out, Rf_install("reason"), why);
    UNPROTECT(1);
  }
  UNPROTECT(1);
  return out;
}

SEXP zar_c_schema_equal(SEXP x, SEXP y, SEXP metadata) {
  struct ArrowError error;
  struct ArrowSchema *sx = zar_schema_from_xptr(x, &error);
  if (sx == NULL) return zar_failure_from_error("handle", &error);
  struct ArrowSchema *sy = zar_schema_from_xptr(y, &error);
  if (sy == NULL) return zar_failure_from_error("handle", &error);
  struct ArrowError reason;
  reason.message[0] = '\0';
  int equal = zar_schema_equal(sx, sy, Rf_asLogical(metadata), "", &reason);
  return zar_equal_result(equal, reason.message);
}

/* Compares two arrays of equal schemas buffer by buffer. Returns 1 or 0,
   or -1 with `error` set when either array is malformed. */
static int zar_arrays_equal(const struct ArrowSchema *schema,
                            const struct ArrowArray *x,
                            const struct ArrowArray *y,
                            struct ArrowError *reason,
                            struct ArrowError *error) {
  struct ArrowArrayView vx, vy;
  int code = ArrowArrayViewInitFromSchema(&vx, schema, error);
  if (code != NANOARROW_OK) return -1;
  code = ArrowArrayViewInitFromSchema(&vy, schema, error);
  if (code != NANOARROW_OK) {
    ArrowArrayViewReset(&vx);
    return -1;
  }
  int equal = -1;
  if (ArrowArrayViewSetArray(&vx, x, error) == NANOARROW_OK &&
      ArrowArrayViewSetArray(&vy, y, error) == NANOARROW_OK &&
      ArrowArrayViewCompare(&vx, &vy, NANOARROW_COMPARE_IDENTICAL, &equal,
                            reason) != NANOARROW_OK) {
    equal = -1;
  }
  ArrowArrayViewReset(&vx);
  ArrowArrayViewReset(&vy);
  return equal;
}

SEXP zar_c_array_equal(SEXP x, SEXP y, SEXP metadata) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArray *ax = zar_array_from_xptr(x, &error);
  if (ax == NULL) return zar_failure_from_error("handle", &error);
  struct ArrowArray *ay = zar_array_from_xptr(y, &error);
  if (ay == NULL) return zar_failure_from_error("handle", &error);
  SEXP tx = zar_array_schema_xptr(x, &error);
  if (tx == NULL) return zar_failure_from_error("handle", &error);
  SEXP ty = zar_array_schema_xptr(y, &error);
  if (ty == NULL) return zar_failure_from_error("handle", &error);
  struct ArrowSchema *sx = zar_schema_from_xptr(tx, &error);
  struct ArrowSchema *sy = zar_schema_from_xptr(ty, &error);

  struct ArrowError reason;
  reason.message[0] = '\0';
  if (!zar_schema_equal(sx, sy, Rf_asLogical(metadata), "schema: ", &reason)) {
    return zar_equal_result(0, reason.message);
  }
  int equal = zar_arrays_equal(sx, ax, ay, &reason, &error);
  if (equal < 0) return zar_failure_from_error("format", &error);
  return zar_equal_result(equal, reason.message);
}

/* Compares two streams batch by batch: equal schemas, the same number of
   batches, and each pair of batches identical. Both are consumed. */
SEXP zar_c_stream_equal(SEXP x, SEXP y, SEXP metadata) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArrayStream *s[2];
  s[0] = zar_stream_from_xptr(x, &error);
  if (s[0] == NULL) return zar_failure_from_error("handle", &error);
  s[1] = zar_stream_from_xptr(y, &error);
  if (s[1] == NULL) return zar_failure_from_error("handle", &error);

  struct ArrowSchema schema[2];
  schema[0].release = NULL;
  schema[1].release = NULL;
  const char *kind = "handle";
  int equal = -1;
  struct ArrowError reason;
  reason.message[0] = '\0';

  for (int i = 0; i < 2; i++) {
    int code = s[i]->get_schema(s[i], &schema[i]);
    if (code != 0) {
      const char *msg = s[i]->get_last_error(s[i]);
      ArrowErrorSet(&error, "the stream could not report its schema: %s",
                    msg == NULL ? strerror(code) : msg);
      goto done;
    }
  }
  if (!zar_schema_equal(&schema[0], &schema[1], Rf_asLogical(metadata),
                        "schema: ", &reason)) {
    equal = 0;
    goto done;
  }

  for (long batch = 0;; batch++) {
    struct ArrowArray a[2];
    a[0].release = NULL;
    a[1].release = NULL;
    for (int i = 0; i < 2; i++) {
      int code = s[i]->get_next(s[i], &a[i]);
      if (code != 0) {
        const char *msg = s[i]->get_last_error(s[i]);
        ArrowErrorSet(&error, "batch %ld could not be read: %s", batch,
                      msg == NULL ? strerror(code) : msg);
        if (a[0].release != NULL) a[0].release(&a[0]);
        equal = -1;
        goto done;
      }
    }
    int ended0 = a[0].release == NULL, ended1 = a[1].release == NULL;
    if (ended0 || ended1) {
      if (!ended0) a[0].release(&a[0]);
      if (!ended1) a[1].release(&a[1]);
      equal = ended0 && ended1;
      if (!equal) {
        ArrowErrorSet(&reason, "the streams have different numbers of batches");
      }
      goto done;
    }
    struct ArrowError inner;
    inner.message[0] = '\0';
    equal = zar_arrays_equal(&schema[0], &a[0], &a[1], &inner, &error);
    a[0].release(&a[0]);
    a[1].release(&a[1]);
    if (equal < 0) {
      kind = "format";
      goto done;
    }
    if (!equal) {
      ArrowErrorSet(&reason, "batch %ld: %s", batch, inner.message);
      goto done;
    }
  }

done:
  if (schema[0].release != NULL) schema[0].release(&schema[0]);
  if (schema[1].release != NULL) schema[1].release(&schema[1]);
  if (equal < 0) return zar_failure_from_error(kind, &error);
  return zar_equal_result(equal, reason.message);
}
