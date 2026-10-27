/* Internal declarations shared by zuarrow's own C files. Nothing here is
   public: the C table of design section 14 comes after v0.1.0. */
#ifndef ZAR_H
#define ZAR_H

#include "nanoarrow.h"

/* Under ZAR_STANDALONE the IPC reader compiles without R, for the fuzz
   target of design section 9: only the declarations below the R block. */
#ifndef ZAR_STANDALONE
#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

/* A length-one character vector from UTF-8 bytes. */
SEXP zar_scalar_utf8(const char *x);

/* A failure is how C reports a condition: a list(kind, message) of class
   "zar_failure" that the R wrapper turns into zuarrow_<kind>_error. R, not
   C, raises conditions, so a C entry point can free what it owns before it
   returns instead of being longjmp'ed over. `kind` is NULL for a plain
   zuarrow_error. */
SEXP zar_failure(const char *kind, const char *message);
SEXP zar_failure_from_error(const char *kind, const struct ArrowError *error);

/* The UTF-8 bytes of a CHARSXP and their length, or NULL when it cannot be
   written as Arrow text: its encoding is "bytes", or its bytes are not
   valid UTF-8. Never raises. */
const char *zar_char_utf8(SEXP s, size_t *len);

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

#endif /* ZAR_STANDALONE */

/* The offset of the first byte that is not valid UTF-8, or -1. */
int64_t zar_utf8_invalid_at(const uint8_t *s, int64_t n);

/* Checks every binary-view and string-view struct in a view and its
   children names a range inside its buffers, which nanoarrow does not. */
int zar_view_check_layout(const struct ArrowArrayView *view, const char *path,
                          struct ArrowError *error);

/* Checks every non-null string in a view and its children is valid UTF-8,
   naming the path to the first that is not. */
int zar_view_validate_utf8(const struct ArrowArrayView *view, const char *path,
                           struct ArrowError *error);

/* The exact text forms read back (src/zar_parse.c). Each returns 0, or
   EINVAL for text that is not of the form, ERANGE for a value the type
   cannot hold exactly. */
int zar_parse_int64(const char *s, int64_t *out);
int zar_parse_uint64(const char *s, uint64_t *out);
int zar_parse_decimal(const char *s, struct ArrowDecimal *decimal);
int zar_parse_date(const char *s, int64_t *days);
int zar_parse_instant(const char *s, int digits, int utc, int64_t *out);
int zar_parse_time(const char *s, int digits, int64_t *out);

/* The condition kind of a reader stream's last failure, or NULL when the
   stream is not one arrow_read() made (src/zar_ipc_read.c). */
const char *zar_reader_kind(const struct ArrowArrayStream *stream);

/* Opens a reader over a copy of `size` bytes into `out`, with the limits
   c(max_message, max_depth, max_batch_rows, max_bytes). On failure returns
   non-zero with `error` and `*kind` set. R-free, for the fuzz target. */
int zar_reader_open_bytes(const uint8_t *data, int64_t size, const double *limits,
                          struct ArrowArrayStream *out, struct ArrowError *error,
                          const char **kind);

#ifndef ZAR_STANDALONE
/* ---- deferred strings (src/zar_altrep.c) -------------------------------- */

/* One batch's part of a deferred string column: `length` elements whose
   offsets start at `offsets` (int32_t, or int64_t when `large`), whose
   bytes are in `data`, and whose validity is bit `validity_offset + i` of
   `validity`, or none when `validity` is NULL. `batch` indexes the array
   handles that own the buffers. */
struct zar_deferred_chunk {
  int64_t begin;
  int64_t length;
  const void *offsets;
  const char *data;
  const uint8_t *validity;
  int64_t validity_offset;
  int64_t batch;
  int large;
};

/* Registers the ALTREP class from R_init_zuarrow(). */
void zar_altrep_init(DllInfo *dll);

/* A character vector over `chunks`, which are copied; its length is where
   the last chunk ends. `arrays` is the list of array handles the chunks
   point into, kept until every element has been created. The bytes must
   already be checked: valid UTF-8 and within R's string length. */
SEXP zar_deferred_strings(SEXP arrays, const struct zar_deferred_chunk *chunks,
                          int64_t n_chunks);

/* Whether `x` is a deferred string vector, and how many of its elements
   have been created: for tests. */
SEXP zar_c_deferred_info(SEXP x);
SEXP zar_c_deferred_probe(SEXP x, SEXP op, SEXP i, SEXP value);
#endif

#endif /* ZAR_H */
