/* libFuzzer target for the IPC reader (design section 9), built with
   ZAR_STANDALONE: no R, no codecs. Each input is opened as an IPC file or
   stream and read to its end; any failure must be a clean error. */
#include <stddef.h>
#include <stdint.h>

#include "zar.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  const double limits[4] = {16.0 * 1024 * 1024, 64.0, 1e6, 64.0 * 1024 * 1024};
  struct ArrowArrayStream stream;
  struct ArrowError error;
  const char *kind = NULL;
  if (zar_reader_open_bytes(data, (int64_t)size, limits, &stream, &error, &kind) != 0) {
    return 0;
  }
  struct ArrowSchema schema;
  if (stream.get_schema(&stream, &schema) == 0) schema.release(&schema);
  for (int i = 0; i < 1000; i++) {
    struct ArrowArray array;
    array.release = NULL;
    if (stream.get_next(&stream, &array) != 0 || array.release == NULL) break;
    array.release(&array);
  }
  stream.release(&stream);
  return 0;
}
