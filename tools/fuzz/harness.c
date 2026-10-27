/* libFuzzer target for the IPC reader (design section 9), built with
   ZAR_STANDALONE: no R, no codecs. Each input is opened as an IPC file or
   stream and read to its end; any failure must be a clean error. A clean
   error names its condition kind and a message: a failure without a kind
   would reach R as an unclassed error, so the target aborts on one, unless
   it is an allocation failure, which has no kind. */
#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "zar.h"

static void zar_check_failure(int code, const char *kind, const char *message) {
  if (code == ENOMEM) return;
  if (kind == NULL || message == NULL || message[0] == '\0') abort();
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  const double limits[4] = {16.0 * 1024 * 1024, 64.0, 1e6, 64.0 * 1024 * 1024};
  struct ArrowArrayStream stream;
  struct ArrowError error;
  error.message[0] = '\0';
  const char *kind = NULL;
  int code = zar_reader_open_bytes(data, (int64_t)size, limits, &stream, &error, &kind);
  if (code != 0) {
    zar_check_failure(code, kind, error.message);
    return 0;
  }
  struct ArrowSchema schema;
  if (stream.get_schema(&stream, &schema) == 0) schema.release(&schema);
  for (int i = 0; i < 1000; i++) {
    struct ArrowArray array;
    array.release = NULL;
    code = stream.get_next(&stream, &array);
    if (code != 0) {
      zar_check_failure(code, zar_reader_recorded_kind(&stream),
                        stream.get_last_error(&stream));
      break;
    }
    if (array.release == NULL) break;
    array.release(&array);
  }
  stream.release(&stream);
  return 0;
}
