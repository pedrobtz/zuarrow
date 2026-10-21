/* Internal declarations shared by zuarrow's own C files. Nothing here is
   public: the C table of design section 14 comes after v0.1.0. */
#ifndef ZAR_H
#define ZAR_H

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>

#include "nanoarrow.h"

/* A length-one character vector from UTF-8 bytes. */
SEXP zar_scalar_utf8(const char *x);

/* A failure is how C reports a condition: a list(kind, message) of class
   "zar_failure" that the R wrapper turns into zuarrow_<kind>_error. R, not
   C, raises conditions, so a C entry point can free what it owns before it
   returns instead of being longjmp'ed over. `kind` is NULL for a plain
   zuarrow_error. */
SEXP zar_failure(const char *kind, const char *message);
SEXP zar_failure_from_error(const char *kind, const struct ArrowError *error);

/* Owning external pointers in the layout nanoarrow's r.h documents (D6): a
   malloc()ed struct whose NULL release means unset, a finalizer that calls
   release, an array's tag holding its schema handle. The class vector is
   c("zuarrow_<kind>", "nanoarrow_<kind>") (D7). */
SEXP zar_schema_owning_xptr(void);
SEXP zar_array_owning_xptr(SEXP schema_xptr);
SEXP zar_stream_owning_xptr(void);

/* Readers that accept any handle in that layout, zuarrow's or another
   producer's. Each returns NULL and fills `error` when `x` is not a live
   handle of its kind. */
struct ArrowSchema *zar_schema_from_xptr(SEXP x, struct ArrowError *error);
struct ArrowArray *zar_array_from_xptr(SEXP x, struct ArrowError *error);
struct ArrowArrayStream *zar_stream_from_xptr(SEXP x, struct ArrowError *error);

/* The schema handle an array handle carries in its tag, or NULL with
   `error` filled when the tag holds none. */
SEXP zar_array_schema_xptr(SEXP array_xptr, struct ArrowError *error);

/* A read-only status: "live", "released" or "null". */
const char *zar_handle_status(SEXP x);

/* A deep copy of the schema behind any schema, array or stream handle into
   a new zuarrow schema handle; a failure when there is none. */
SEXP zar_schema_copy_of(SEXP x);

/* The offset of the first byte that is not valid UTF-8, or -1. */
int64_t zar_utf8_invalid_at(const uint8_t *s, int64_t n);

/* Checks every non-null string in a view and its children is valid UTF-8,
   naming the path to the first that is not. */
int zar_view_validate_utf8(const struct ArrowArrayView *view, const char *path,
                           struct ArrowError *error);

#endif /* ZAR_H */
