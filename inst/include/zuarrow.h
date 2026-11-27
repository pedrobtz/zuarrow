/* zuarrow -- the family's Arrow layer in C (design section 14.1).
 *
 * The R-free C API that a package reaches through `LinkingTo: zuarrow`,
 * linked from the static archive libzuarrow.a that zuarrow installs in
 * <pkg>/lib${R_ARCH}. It needs no R at run time and calls none: zuarrow's
 * namespace is never loaded by it.
 *
 *   zuarrow.h            this file: the Arrow C data and stream structs,
 *                        the IPC reader as a stream, the exact text
 *                        parsers and the UTF-8 check.
 *   zuarrow/nanoarrow.h  the nanoarrow 0.9.0 zuarrow bundles, namespaced
 *                        (every function is zuarrowArrow*) and patched as
 *                        zuarrow builds it, so a reader builds its arrays
 *                        and streams with the copy the archive holds:
 *                        ArrowSchemaInit*, ArrowArrayInitFromSchema,
 *                        ArrowArrayAppend*, ArrowArrayFinishBuilding*,
 *                        ArrowBasicArrayStreamInit and the rest.
 *   zukomp.h             the zukomp header zuarrow was compiled against,
 *                        which types the codec table below.
 *
 * Every function here may be called from any thread, R's main thread or
 * not. None calls R, longjmps, aborts or writes to stdout or stderr: each
 * returns a code, and the archive holds no mutable global, so distinct
 * streams share nothing.
 *
 * Copyright (c) 2026 Pedro Baltazar. MIT licensed; see zuarrow's LICENSE.
 */
#ifndef ZUARROW_H
#define ZUARROW_H

#include <stddef.h>
#include <stdint.h>

#include "zukomp.h"

#if !defined(ZUKOMP_ABI_VERSION) || ZUKOMP_ABI_VERSION != 1
#error "zuarrow.h is written against zukomp's ABI 1"
#endif

/* Changes when a declaration a reader can reach changes: one here, or one
   in zuarrow/nanoarrow.h through a re-vendor or a patch (design section
   14.1). A reader built against one value is rebuilt for the next; an
   appended options field changes nothing, struct_size covers it. */
#define ZUARROW_ABI_VERSION 1

#ifdef __cplusplus
extern "C" {
#endif

/* ---- the Arrow C data and stream interfaces ---------------------------- */

/* As the Arrow specification gives them, under its guards, so this header
   and any other that defines them (nanoarrow's, Arrow's, DuckDB's) can be
   included together. */

#ifndef ARROW_C_DATA_INTERFACE
#define ARROW_C_DATA_INTERFACE

#define ARROW_FLAG_DICTIONARY_ORDERED 1
#define ARROW_FLAG_NULLABLE 2
#define ARROW_FLAG_MAP_KEYS_SORTED 4

struct ArrowSchema {
  /* Array type description */
  const char *format;
  const char *name;
  const char *metadata;
  int64_t flags;
  int64_t n_children;
  struct ArrowSchema **children;
  struct ArrowSchema *dictionary;

  /* Release callback */
  void (*release)(struct ArrowSchema *);
  /* Opaque producer-specific data */
  void *private_data;
};

struct ArrowArray {
  /* Array data description */
  int64_t length;
  int64_t null_count;
  int64_t offset;
  int64_t n_buffers;
  int64_t n_children;
  const void **buffers;
  struct ArrowArray **children;
  struct ArrowArray *dictionary;

  /* Release callback */
  void (*release)(struct ArrowArray *);
  /* Opaque producer-specific data */
  void *private_data;
};

#endif /* ARROW_C_DATA_INTERFACE */

#ifndef ARROW_C_STREAM_INTERFACE
#define ARROW_C_STREAM_INTERFACE

struct ArrowArrayStream {
  /* Callbacks providing stream functionality */
  int (*get_schema)(struct ArrowArrayStream *, struct ArrowSchema *out);
  int (*get_next)(struct ArrowArrayStream *, struct ArrowArray *out);
  const char *(*get_last_error)(struct ArrowArrayStream *);

  /* Release callback */
  void (*release)(struct ArrowArrayStream *);

  /* Opaque producer-specific data */
  void *private_data;
};

#endif /* ARROW_C_STREAM_INTERFACE */

/* ---- the IPC reader ----------------------------------------------------- */

/* What zuarrow_open_stream() reads, and how much. struct_size comes first:
   set it to sizeof(zuarrow_options) as you compiled it, which
   zuarrow_options_init() does. A later version appends fields and reads
   them only when struct_size covers them; it never needs more than
   ZUARROW_OPTIONS_REQUIRED_SIZE. */
typedef struct zuarrow_options {
  uint32_t struct_size;

  /* The top-level columns to keep, in the order given, by name or by
     0-based position: n_columns entries of `columns` or of
     `column_indices`, never both. Both NULL keeps every column. A name
     matches the first field of that name; a name no field has, or a
     position outside the schema, is an error of kind "type". */
  const char *const *columns;
  const int64_t *column_indices;
  int64_t n_columns;

  /* The limits of arrow_limits(), bound before the bytes they cover are
     used; going over one is an error of kind "limit". Each must be a
     non-negative number; the doubles may be INFINITY. */
  double max_message;    /* bytes in one message header or body, and one
                            compressed buffer's declared size */
  int32_t max_depth;     /* schema nesting, a top-level column being 1 */
  double max_batch_rows; /* rows in one record batch or dictionary */
  double max_bytes;      /* bytes of input in all */
  double max_dictionary; /* bytes delta dictionaries may build in all */

  /* zukomp's codec table, for LZ4_FRAME and ZSTD bodies, or NULL. With
     NULL a compressed body is an error of kind "codec". The archive holds
     no codec: an R package gets the table from zukomp_api() in
     zukomp-r.h. It must outlive every stream opened with it. */
  const zukomp_api_v1 *codecs;
} zuarrow_options;

#define ZUARROW_OPTIONS_REQUIRED_SIZE \
  (offsetof(zuarrow_options, codecs) + sizeof(const zukomp_api_v1 *))

/* Sets struct_size, keeps every column, takes no codec table, and sets the
   limits to arrow_limits()'s defaults: max_message 2^31 - 1, max_depth 64,
   max_batch_rows 2^31 - 1, max_bytes infinite, max_dictionary 2^28. */
void zuarrow_options_init(zuarrow_options *options);

/* Opens the Arrow IPC file or stream at `path` as an ArrowArrayStream in
 * `out`, which the caller releases. The framing is found from the first
 * bytes. The file is read whole into memory and closed before this
 * returns; `path` is passed to fopen() as it is, in the native encoding.
 * `options` may be NULL for zuarrow_options_init()'s defaults.
 *
 * The stream is arrow_read()'s reader: every message verified, every
 * buffer inside its message, every limit bound, each batch validated at
 * nanoarrow's full level and its strings checked as strict UTF-8 before
 * get_next() returns it. Batches own their memory and outlive the stream.
 * Not thread-safe per stream: use one stream from one thread at a time.
 *
 * Returns 0, or an errno code: EINVAL for malformed input, an argument or
 * a limit, EIO for a file that cannot be read, ENOTSUP for a codec that
 * is missing, ENOMEM. On failure `out` is still a stream, in an error
 * state: get_schema() and get_next() return the same code,
 * get_last_error() says why and zuarrow_error_kind() names the kind; it
 * must be released like any other. Only when even that cannot be
 * allocated is ENOMEM returned with out->release NULL.
 *
 * A get_next() that fails returns non-zero, leaves the array released,
 * and the stream stays failed: every later call returns the same code and
 * message, so no batch is skipped or read against a dictionary that did
 * not arrive. */
int zuarrow_open_stream(const char *path, const zuarrow_options *options,
                        struct ArrowArrayStream *out);

/* The kind of the last failure of a stream zuarrow_open_stream() made:
   "format", "limit", "codec", "io", "type", or "memory" for an
   allocation that failed. These are the suffixes of the conditions
   arrow_read() raises for the same input (zuarrow_<kind>_error; "memory"
   is a plain zuarrow_error). NULL when the stream has not failed, or was
   not made here. */
const char *zuarrow_error_kind(const struct ArrowArrayStream *stream);

/* The ZUARROW_ABI_VERSION the archive was built with. */
uint32_t zuarrow_abi_version(void);

/* ---- exact text --------------------------------------------------------- */

/* The exact text forms of design section 6.3 that arrow_array() reads
 * back, so every text reader applies the same rules. Each takes a
 * NUL-terminated string and returns 0, EINVAL for text that is not of the
 * form, or ERANGE for text of the form whose value the type cannot hold
 * exactly or that is not canonical: no "+" sign, no leading zero, no
 * "-0", every fraction digit of the unit or scale. Nothing is rounded.
 * `out` is meaningful only when 0 is returned. */

/* An optional "-" and decimal digits. */
int zuarrow_parse_int64(const char *s, int64_t *out);

/* Decimal digits. */
int zuarrow_parse_uint64(const char *s, uint64_t *out);

/* "[-]digits[.digits]" with exactly decimal->scale fraction digits (none
   when the scale is not positive) and at most decimal->precision digits,
   into `decimal`, which ArrowDecimalInit() from zuarrow/nanoarrow.h has
   set up with its bit width, precision and scale. */
struct ArrowDecimal;
int zuarrow_parse_decimal(const char *s, struct ArrowDecimal *decimal);

/* "YYYY-MM-DD", proleptic Gregorian, into days since 1970-01-01. A year
   outside 0000 to 9999 is signed and has no leading zero: "+10000-01-01",
   "-0001-01-01". */
int zuarrow_parse_date(const char *s, int64_t *days);

/* "YYYY-MM-DDTHH:MM:SS[.f]", the date as zuarrow_parse_date() reads it,
   with exactly `digits` fraction digits (0 to 9, else EINVAL; a unit is 0,
   3, 6 or 9) and, when `utc` is non-zero, a trailing "Z", into units of
   10^-digits seconds since 1970-01-01T00:00:00. */
int zuarrow_parse_instant(const char *s, int digits, int utc, int64_t *out);

/* "HH:MM:SS[.f]", from 00:00:00 to below 24:00:00, with exactly `digits`
   fraction digits, into units of 10^-digits seconds since midnight. */
int zuarrow_parse_time(const char *s, int digits, int64_t *out);

/* The offset of the first byte of s[0..n) that is not strict UTF-8 (RFC
   3629: no overlong form, no surrogate, nothing above U+10FFFF), or -1
   when every byte is. The rule of R's validUTF8() and of the reader. */
int64_t zuarrow_utf8_invalid_at(const uint8_t *s, int64_t n);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ZUARROW_H */
