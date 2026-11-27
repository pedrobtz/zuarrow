/* libFuzzer target for the IPC reader (design section 9), built with
   ZAR_STANDALONE: no R, no codecs. Each input is written to a file and
   opened through the static archive's public entry point,
   zuarrow_open_stream() (design section 14.1), as an IPC file or stream,
   and read to its end. Its first 64 bytes, as text, also go through the
   public exact parsers, which must return 0, EINVAL or ERANGE.

   A failure must be a clean error. A clean error names its condition kind
   and a message: a failure without a kind would reach R as an unclassed
   error, so the target aborts on one, unless it is an allocation failure,
   which has no kind.

   What does decode is checked too (#185), and the target aborts on any
   violation:

   - the schema nests no deeper than max_depth, and its names and metadata
     keys can become R strings;
   - every batch validates again at nanoarrow's full level, with the
     view-layout and strict UTF-8 checks the reader makes, from a fresh
     view over the schema the stream reports;
   - a batch holds at most max_batch_rows rows, each column holds exactly
     the batch's rows, every dictionary at most max_batch_rows values, and
     no buffer is over max_message bytes;
   - a schema without dictionaries round-trips: the decoded batches,
     written again by nanoarrow's writer and read again by the reader, give
     the same schema and identical batches. A type the writer cannot
     encode leaves that input without the round trip. */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "zar.h"
#include "nanoarrow_ipc.h"
#include "zuarrow.h"

#define ZAR_FUZZ_MAX_BATCHES 1000

static void zar_check_failure(int code, const char *kind, const char *message) {
  if (code == ENOMEM) return;
  if (kind == NULL || message == NULL || message[0] == '\0') abort();
  if (strcmp(kind, "memory") == 0) abort();
}

/* The file each input is written to: one per process, made once. */
static char zar_fuzz_path[64];

int LLVMFuzzerInitialize(int *argc, char ***argv) {
  (void)argc;
  (void)argv;
  snprintf(zar_fuzz_path, sizeof(zar_fuzz_path), "/tmp/zuarrow-fuzz-XXXXXX");
  int fd = mkstemp(zar_fuzz_path);
  if (fd < 0) abort();
  close(fd);
  return 0;
}

static void zar_fuzz_write(const uint8_t *data, size_t size) {
  FILE *f = fopen(zar_fuzz_path, "wb");
  if (f == NULL) abort();
  if (size > 0 && fwrite(data, 1, size, f) != size) abort();
  if (fclose(f) != 0) abort();
}

/* Every parser answers 0, EINVAL or ERANGE, and a valid UTF-8 prefix ends
   where zuarrow_utf8_invalid_at() says. */
static void zar_fuzz_text(const uint8_t *data, size_t size) {
  char text[65];
  size_t n = size < 64 ? size : 64;
  memcpy(text, data, n);
  text[n] = '\0';
  int64_t i64;
  uint64_t u64;
  int codes[7];
  codes[0] = zuarrow_parse_int64(text, &i64);
  codes[1] = zuarrow_parse_uint64(text, &u64);
  codes[2] = zuarrow_parse_date(text, &i64);
  codes[3] = zuarrow_parse_instant(text, n > 0 ? data[0] % 10 : 0, 1, &i64);
  codes[4] = zuarrow_parse_time(text, n > 1 ? data[1] % 10 : 0, &i64);
  struct ArrowDecimal decimal;
  ArrowDecimalInit(&decimal, 128, 38, n > 2 ? (int32_t)(data[2] % 40) - 2 : 2);
  codes[5] = zuarrow_parse_decimal(text, &decimal);
  ArrowDecimalInit(&decimal, 256, 76, n > 2 ? (int32_t)(data[2] % 80) - 2 : 2);
  codes[6] = zuarrow_parse_decimal(text, &decimal);
  for (int k = 0; k < 7; k++) {
    if (codes[k] != 0 && codes[k] != EINVAL && codes[k] != ERANGE) abort();
  }
  int64_t at = zuarrow_utf8_invalid_at(data, (int64_t)size);
  if (at < -1 || at >= (int64_t)size) abort();
  if (at > 0 && zuarrow_utf8_invalid_at(data, at) != -1) abort();
}

/* The reader's own depth rule, restated: a leaf field is depth 1 and the
   top-level struct does not count. */
static int zar_fuzz_depth(const struct ArrowSchema *s) {
  int depth = 0;
  for (int64_t i = 0; i < s->n_children; i++) {
    int d = zar_fuzz_depth(s->children[i]);
    if (d > depth) depth = d;
  }
  if (s->dictionary != NULL) {
    int d = zar_fuzz_depth(s->dictionary);
    if (d > depth) depth = d;
  }
  return depth + 1;
}

static int zar_fuzz_has_dictionary(const struct ArrowSchema *s) {
  if (s->dictionary != NULL) return 1;
  for (int64_t i = 0; i < s->n_children; i++) {
    if (zar_fuzz_has_dictionary(s->children[i])) return 1;
  }
  return 0;
}

static int zar_fuzz_same_text(const char *a, const char *b) {
  if (a == NULL || b == NULL) return a == b;
  return strcmp(a, b) == 0;
}

static int zar_fuzz_same_metadata(const char *a, const char *b) {
  int64_t na = a == NULL ? 0 : ArrowMetadataSizeOf(a);
  int64_t nb = b == NULL ? 0 : ArrowMetadataSizeOf(b);
  /* An empty metadata block and none are the same. */
  if (na <= 4 && nb <= 4) return 1;
  return na == nb && memcmp(a, b, (size_t)na) == 0;
}

/* Format, name, flags and metadata, recursively. */
static int zar_fuzz_same_schema(const struct ArrowSchema *a, const struct ArrowSchema *b) {
  if (a == NULL || b == NULL) return a == b;
  if (!zar_fuzz_same_text(a->format, b->format)) return 0;
  if (!zar_fuzz_same_text(a->name, b->name)) return 0;
  if (a->flags != b->flags) return 0;
  if (!zar_fuzz_same_metadata(a->metadata, b->metadata)) return 0;
  if (a->n_children != b->n_children) return 0;
  for (int64_t i = 0; i < a->n_children; i++) {
    if (!zar_fuzz_same_schema(a->children[i], b->children[i])) return 0;
  }
  return zar_fuzz_same_schema(a->dictionary, b->dictionary);
}

/* The limits on what a view holds: every dictionary at most `max_rows`
   values, every buffer at most `max_bytes` bytes. */
static void zar_fuzz_check_view(const struct ArrowArrayView *v, double max_rows,
                                double max_bytes) {
  for (int i = 0; i < NANOARROW_MAX_FIXED_BUFFERS; i++) {
    if ((double)v->buffer_views[i].size_bytes > max_bytes) abort();
  }
  for (int64_t i = 0; i < v->n_variadic_buffers; i++) {
    if ((double)v->variadic_buffer_sizes[i] > max_bytes) abort();
  }
  for (int64_t i = 0; i < v->n_children; i++) {
    zar_fuzz_check_view(v->children[i], max_rows, max_bytes);
  }
  if (v->dictionary != NULL) {
    if ((double)v->dictionary->length > max_rows) abort();
    zar_fuzz_check_view(v->dictionary, max_rows, max_bytes);
  }
}

/* Checks one decoded batch against the schema and the limits, and leaves
   `view` set to it. */
static void zar_fuzz_check_batch(struct ArrowArrayView *view, const struct ArrowArray *array,
                                 const double *limits) {
  struct ArrowError error;
  if (array->length < 0 || (double)array->length > limits[2]) abort();
  if (array->offset != 0) abort();
  if (ArrowArrayViewSetArray(view, array, &error) != NANOARROW_OK) abort();
  if (ArrowArrayViewValidate(view, NANOARROW_VALIDATION_LEVEL_FULL, &error) != NANOARROW_OK) {
    abort();
  }
  if (zar_view_check_layout(view, "", &error) != NANOARROW_OK) abort();
  if (zar_view_validate_utf8(view, "", &error) != NANOARROW_OK) abort();
  for (int64_t i = 0; i < view->n_children; i++) {
    if (view->children[i]->length != array->length) abort();
  }
  zar_fuzz_check_view(view, limits[2], limits[0]);
}

/* Reads `written` back and compares it with the schema and batches it was
   written from. The limits are loose where the writer may need more room
   than the input had: buffers the input shared are written apart, and a
   column of nulls holds up to 8 values for each body byte it came with. */
static void zar_fuzz_compare(const struct ArrowBuffer *written, const struct ArrowSchema *schema,
                             struct ArrowArray *arrays, int64_t n, const double *limits,
                             int64_t input_size) {
  double rows = limits[2];
  if (8.0 * (double)input_size > rows) rows = 8.0 * (double)input_size;
  const double loose[5] = {1e15, limits[1], rows, 1e15, 1e15};
  struct ArrowArrayStream stream;
  struct ArrowError error;
  const char *kind = NULL;
  if (zar_reader_open_bytes(written->data, written->size_bytes, loose, &stream, &error,
                            &kind) != NANOARROW_OK) {
    abort();
  }
  struct ArrowSchema again;
  if (stream.get_schema(&stream, &again) != NANOARROW_OK) abort();
  if (!zar_fuzz_same_schema(schema, &again)) abort();

  struct ArrowArrayView expected, actual;
  if (ArrowArrayViewInitFromSchema(&expected, schema, &error) != NANOARROW_OK) abort();
  if (ArrowArrayViewInitFromSchema(&actual, &again, &error) != NANOARROW_OK) abort();
  for (int64_t i = 0; i <= n; i++) {
    struct ArrowArray array;
    array.release = NULL;
    if (stream.get_next(&stream, &array) != NANOARROW_OK) abort();
    if (i == n) {
      /* The stream ends where the batches written do. */
      if (array.release != NULL) abort();
      break;
    }
    if (array.release == NULL) abort();
    if (ArrowArrayViewSetArray(&expected, &arrays[i], &error) != NANOARROW_OK) abort();
    if (ArrowArrayViewSetArray(&actual, &array, &error) != NANOARROW_OK) abort();
    int same = 0;
    if (ArrowArrayViewCompare(&actual, &expected, NANOARROW_COMPARE_IDENTICAL, &same,
                              &error) != NANOARROW_OK ||
        !same) {
      abort();
    }
    array.release(&array);
  }
  ArrowArrayViewReset(&expected);
  ArrowArrayViewReset(&actual);
  again.release(&again);
  stream.release(&stream);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  const double limits[5] = {16.0 * 1024 * 1024, 64.0, 1e6, 64.0 * 1024 * 1024,
                            64.0 * 1024 * 1024};
  zar_fuzz_text(data, size);
  zar_fuzz_write(data, size);
  zuarrow_options options;
  zuarrow_options_init(&options);
  options.max_message = limits[0];
  options.max_depth = (int32_t)limits[1];
  options.max_batch_rows = limits[2];
  options.max_bytes = limits[3];
  options.max_dictionary = limits[4];
  struct ArrowArrayStream stream;
  struct ArrowError error;
  error.message[0] = '\0';
  int code = zuarrow_open_stream(zar_fuzz_path, &options, &stream);
  if (code != 0) {
    if (stream.release == NULL) {
      if (code != ENOMEM) abort();
      return 0;
    }
    /* The error stream repeats the failure and names its kind. */
    struct ArrowArray none;
    if (stream.get_next(&stream, &none) != code || none.release != NULL) abort();
    zar_check_failure(code, zar_api_recorded_kind(&stream), stream.get_last_error(&stream));
    if (code != ENOMEM && strcmp(zuarrow_error_kind(&stream), zar_api_recorded_kind(&stream))) {
      abort();
    }
    stream.release(&stream);
    return 0;
  }
  if ((double)size > limits[3]) abort();

  struct ArrowSchema schema;
  if (stream.get_schema(&stream, &schema) != NANOARROW_OK) abort();
  if (zar_fuzz_depth(&schema) - 1 > (int)limits[1]) abort();
  if (zar_schema_check_text(&schema, &error) != NANOARROW_OK) abort();
  struct ArrowArrayView view;
  if (ArrowArrayViewInitFromSchema(&view, &schema, &error) != NANOARROW_OK) abort();

  /* The round trip: nanoarrow's writer, into memory. */
  int trip = !zar_fuzz_has_dictionary(&schema);
  struct ArrowBuffer written;
  ArrowBufferInit(&written);
  struct ArrowIpcWriter writer;
  writer.private_data = NULL;
  if (trip) {
    struct ArrowIpcOutputStream output;
    trip = ArrowIpcOutputStreamInitBuffer(&output, &written) == NANOARROW_OK &&
           ArrowIpcWriterInit(&writer, &output) == NANOARROW_OK;
  }
  if (trip) trip = ArrowIpcWriterWriteSchema(&writer, &schema, &error) == NANOARROW_OK;

  struct ArrowArray *arrays =
      (struct ArrowArray *)calloc(ZAR_FUZZ_MAX_BATCHES, sizeof(struct ArrowArray));
  if (arrays == NULL) trip = 0;
  int64_t n = 0;
  for (int i = 0; i < ZAR_FUZZ_MAX_BATCHES; i++) {
    struct ArrowArray array;
    array.release = NULL;
    code = stream.get_next(&stream, &array);
    if (code != 0) {
      zar_check_failure(code, zar_api_recorded_kind(&stream), stream.get_last_error(&stream));
      const char *named = zuarrow_error_kind(&stream);
      if (code != ENOMEM && (named == NULL || strcmp(named, zar_api_recorded_kind(&stream)))) {
        abort();
      }
      /* A failed stream stays failed. */
      struct ArrowArray again;
      if (stream.get_next(&stream, &again) != code || again.release != NULL) abort();
      break;
    }
    if (array.release == NULL) break;
    zar_fuzz_check_batch(&view, &array, limits);
    if (trip) trip = ArrowIpcWriterWriteArrayView(&writer, &view, &error) == NANOARROW_OK;
    if (trip) {
      arrays[n++] = array;
    } else {
      array.release(&array);
    }
  }
  if (trip) trip = ArrowIpcWriterWriteArrayView(&writer, NULL, &error) == NANOARROW_OK;
  if (trip) zar_fuzz_compare(&written, &schema, arrays, n, limits, (int64_t)size);

  for (int64_t i = 0; i < n; i++) arrays[i].release(&arrays[i]);
  free(arrays);
  if (writer.private_data != NULL) ArrowIpcWriterReset(&writer);
  ArrowBufferReset(&written);
  ArrowArrayViewReset(&view);
  schema.release(&schema);
  stream.release(&stream);
  return 0;
}
