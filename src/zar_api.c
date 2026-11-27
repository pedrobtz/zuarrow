/* The public C API of inst/include/zuarrow.h (design section 14.1): the
   IPC reader opened from a path with options, R-free. It is compiled into
   the static archive libzuarrow.a with ZAR_STANDALONE, and into zuarrow.so
   too, hidden, so the package's own tests reach it through a test entry
   point (src/zar_api_r.c) with zukomp's table. Nothing here may call R,
   abort, write to stdout or stderr, or keep a mutable global. */
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "zar.h"
#include "zuarrow.h"

/* ---- options -------------------------------------------------------- */

void zuarrow_options_init(zuarrow_options *options) {
  if (options == NULL) return;
  memset(options, 0, sizeof(*options));
  options->struct_size = (uint32_t)sizeof(*options);
  options->max_message = 2147483647.0;
  options->max_depth = 64;
  options->max_batch_rows = 2147483647.0;
  options->max_bytes = INFINITY;
  options->max_dictionary = 268435456.0;
}

uint32_t zuarrow_abi_version(void) { return ZUARROW_ABI_VERSION; }

/* ---- a stream that only reports how opening failed ------------------- */

struct zar_api_failed {
  int code;
  const char *kind;
  const char *recorded; /* the reader's own kind, NULL when it named none */
  char message[1024];
};

static int zar_failed_get_schema(struct ArrowArrayStream *stream, struct ArrowSchema *out) {
  NANOARROW_UNUSED(out);
  return ((struct zar_api_failed *)stream->private_data)->code;
}

static int zar_failed_get_next(struct ArrowArrayStream *stream, struct ArrowArray *out) {
  out->release = NULL;
  return ((struct zar_api_failed *)stream->private_data)->code;
}

static const char *zar_failed_last_error(struct ArrowArrayStream *stream) {
  return ((struct zar_api_failed *)stream->private_data)->message;
}

static void zar_failed_release(struct ArrowArrayStream *stream) {
  free(stream->private_data);
  stream->private_data = NULL;
  stream->release = NULL;
}

/* Leaves `out` a stream that repeats `code`, `kind` and `message`, and
   returns `code`. When that cannot be allocated, out->release stays NULL
   and the answer is ENOMEM. */
static int zar_api_fail(struct ArrowArrayStream *out, int code, const char *kind,
                        const char *message) {
  out->release = NULL;
  struct zar_api_failed *f = (struct zar_api_failed *)calloc(1, sizeof(*f));
  if (f == NULL) return ENOMEM;
  f->code = code == 0 ? EINVAL : code;
  f->kind = code == ENOMEM ? "memory" : (kind == NULL ? "format" : kind);
  f->recorded = kind;
  size_t n = strlen(message);
  if (n >= sizeof(f->message)) n = sizeof(f->message) - 1;
  memcpy(f->message, message, n);
  f->message[n] = '\0';
  out->get_schema = &zar_failed_get_schema;
  out->get_next = &zar_failed_get_next;
  out->get_last_error = &zar_failed_last_error;
  out->release = &zar_failed_release;
  out->private_data = f;
  return f->code;
}

const char *zuarrow_error_kind(const struct ArrowArrayStream *stream) {
  if (stream == NULL || stream->release == NULL) return NULL;
  if (stream->get_next == &zar_failed_get_next) {
    return ((const struct zar_api_failed *)stream->private_data)->kind;
  }
  int code = zar_reader_failure(stream);
  if (code == 0) return NULL;
  if (code == ENOMEM) return "memory";
  const char *kind = zar_reader_recorded_kind(stream);
  return kind == NULL ? "format" : kind;
}

/* The kind the failure recorded itself, before zuarrow_error_kind()'s
   defaults: NULL for an allocation failure, and for any failure that named
   no kind, which the fuzz target treats as a bug. */
const char *zar_api_recorded_kind(const struct ArrowArrayStream *stream) {
  if (stream->get_next == &zar_failed_get_next) {
    return ((const struct zar_api_failed *)stream->private_data)->recorded;
  }
  return zar_reader_recorded_kind(stream);
}

/* ---- opening -------------------------------------------------------- */

static int zar_api_limit_ok(double x) { return !isnan(x) && x >= 0; }

/* Whether `codecs` is a zukomp table this reader can call: the ABI it was
   compiled against, and long enough to hold every entry it uses. */
static int zar_api_codecs_ok(const zukomp_api_v1 *codecs) {
  size_t need = offsetof(zukomp_api_v1, status_string) + sizeof(codecs->status_string);
  return codecs->abi_version == ZUKOMP_ABI_VERSION && codecs->struct_size >= need &&
         codecs->codec_available != NULL && codecs->decompress_one != NULL &&
         codecs->status_string != NULL;
}

/* The 0-based field indices of the selected names: the first field of each
   name. Returns NULL with `error` set when a name is absent or memory runs
   out (`*code` says which). */
static int64_t *zar_api_match(struct ArrowArrayStream *stream, const char *const *names,
                              int64_t n, struct ArrowError *error, int *code) {
  struct ArrowSchema schema;
  schema.release = NULL;
  *code = stream->get_schema(stream, &schema);
  if (*code != NANOARROW_OK) {
    ArrowErrorSet(error, "cannot allocate a copy of the schema");
    return NULL;
  }
  int64_t *idx = (int64_t *)malloc(n > 0 ? (size_t)n * sizeof(int64_t) : sizeof(int64_t));
  if (idx == NULL) {
    schema.release(&schema);
    ArrowErrorSet(error, "cannot allocate the selection");
    *code = ENOMEM;
    return NULL;
  }
  for (int64_t k = 0; k < n; k++) {
    idx[k] = -1;
    if (names[k] == NULL) {
      ArrowErrorSet(error, "column name %ld is NULL", (long)k);
      break;
    }
    for (int64_t i = 0; i < schema.n_children; i++) {
      const char *name = schema.children[i]->name;
      if (name != NULL && strcmp(name, names[k]) == 0) {
        idx[k] = i;
        break;
      }
    }
    if (idx[k] < 0) {
      ArrowErrorSet(error, "no column called '%s'", names[k]);
      break;
    }
  }
  schema.release(&schema);
  for (int64_t k = 0; k < n; k++) {
    if (idx[k] < 0) {
      free(idx);
      *code = EINVAL;
      return NULL;
    }
  }
  return idx;
}

int zuarrow_open_stream(const char *path, const zuarrow_options *options,
                        struct ArrowArrayStream *out) {
  if (out == NULL) return EINVAL;
  out->release = NULL;
  zuarrow_options defaults;
  if (options == NULL) {
    zuarrow_options_init(&defaults);
    options = &defaults;
  }
  if (options->struct_size < ZUARROW_OPTIONS_REQUIRED_SIZE) {
    return zar_api_fail(out, EINVAL, "type",
                        "options->struct_size is smaller than zuarrow_options; "
                        "set it with zuarrow_options_init()");
  }
  if (path == NULL) return zar_api_fail(out, EINVAL, "type", "the path is NULL");
  if (options->columns != NULL && options->column_indices != NULL) {
    return zar_api_fail(out, EINVAL, "type",
                        "select columns by name or by position, not both");
  }
  if (options->n_columns < 0 ||
      (options->n_columns > 0 && options->columns == NULL &&
       options->column_indices == NULL)) {
    return zar_api_fail(out, EINVAL, "type",
                        "n_columns does not match the columns given");
  }
  if (!zar_api_limit_ok(options->max_message) || options->max_depth < 0 ||
      !zar_api_limit_ok(options->max_batch_rows) || !zar_api_limit_ok(options->max_bytes) ||
      !zar_api_limit_ok(options->max_dictionary)) {
    return zar_api_fail(out, EINVAL, "type", "every limit must be a non-negative number");
  }
  if (options->codecs != NULL && !zar_api_codecs_ok(options->codecs)) {
    return zar_api_fail(out, EINVAL, "codec",
                        "the codec table is not zukomp's ABI 1 table");
  }

  const double limits[5] = {options->max_message, (double)options->max_depth,
                            options->max_batch_rows, options->max_bytes,
                            options->max_dictionary};
  struct ArrowError error;
  error.message[0] = '\0';
  const char *kind = NULL;
  int code = zar_reader_open_path(path, limits, (const void *)options->codecs, out, &error,
                                  &kind);
  if (code != NANOARROW_OK) {
    out->release = NULL;
    return zar_api_fail(out, code, kind, error.message);
  }

  if (options->columns == NULL && options->column_indices == NULL) return NANOARROW_OK;
  int64_t *idx = NULL;
  if (options->columns != NULL) {
    idx = zar_api_match(out, options->columns, options->n_columns, &error, &code);
    kind = "type";
  } else {
    idx = (int64_t *)options->column_indices;
  }
  if (idx != NULL) {
    code = zar_reader_select(out, idx, options->n_columns, &error, &kind);
    if (options->columns != NULL) free(idx);
  }
  if (code != NANOARROW_OK) {
    out->release(out);
    return zar_api_fail(out, code, kind, error.message);
  }
  return NANOARROW_OK;
}

/* ---- exact text ------------------------------------------------------ */

int zuarrow_parse_int64(const char *s, int64_t *out) { return zar_parse_int64(s, out); }

int zuarrow_parse_uint64(const char *s, uint64_t *out) { return zar_parse_uint64(s, out); }

int zuarrow_parse_decimal(const char *s, struct ArrowDecimal *decimal) {
  return zar_parse_decimal(s, decimal);
}

int zuarrow_parse_date(const char *s, int64_t *days) { return zar_parse_date(s, days); }

/* zar_parse.c scales by 10^digits in int64_t, which holds up to 10^18;
   Arrow's units need at most 9. */
int zuarrow_parse_instant(const char *s, int digits, int utc, int64_t *out) {
  if (digits < 0 || digits > 9) return EINVAL;
  return zar_parse_instant(s, digits, utc, out);
}

int zuarrow_parse_time(const char *s, int digits, int64_t *out) {
  if (digits < 0 || digits > 9) return EINVAL;
  return zar_parse_time(s, digits, out);
}

int64_t zuarrow_utf8_invalid_at(const uint8_t *s, int64_t n) {
  return zar_utf8_invalid_at(s, n);
}
