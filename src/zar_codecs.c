/* The IPC body codecs (design D2, section 6.7): nanoarrow's decompression
   hook driven through zukomp's C table, with the 8-byte length prefix as
   the expected size and the bound on the output. A body that decodes to
   any other size is an error, so a lying prefix never passes. */
#include <inttypes.h>
#include <string.h>

#include "zar.h"
#include "nanoarrow_ipc.h"

#ifdef ZAR_STANDALONE

/* Without R there is no zukomp: compressed bodies stay compressed and are
   a codec error, so the fuzz target exercises framing and validation. */
const void *zar_codecs_api(void) { return NULL; }

int zar_codec_decompress(const void *table, int codec, const uint8_t *src,
                         int64_t src_size, uint8_t *dst, int64_t dst_size,
                         struct ArrowError *error, const char **kind) {
  NANOARROW_UNUSED(table);
  NANOARROW_UNUSED(src);
  NANOARROW_UNUSED(src_size);
  NANOARROW_UNUSED(dst);
  NANOARROW_UNUSED(dst_size);
  *kind = "codec";
  ArrowErrorSet(error, "codec %d is not built into the standalone reader", codec);
  return ENOTSUP;
}

#else

#include <R_ext/Rdynload.h>
#include "zukomp-r.h"

static zu_codec zar_codec_id(int codec) {
  switch (codec) {
    case NANOARROW_IPC_COMPRESSION_TYPE_LZ4_FRAME:
      return ZU_CODEC_LZ4_FRAME;
    case NANOARROW_IPC_COMPRESSION_TYPE_ZSTD:
      return ZU_CODEC_ZSTD;
    default:
      return ZU_CODEC_NONE;
  }
}

/* zukomp's table, resolved once while R is running the reader's .Call. */
const void *zar_codecs_api(void) { return (const void *)zukomp_api(); }

int zar_codec_decompress(const void *table, int codec, const uint8_t *src,
                         int64_t src_size, uint8_t *dst, int64_t dst_size,
                         struct ArrowError *error, const char **kind) {
  const zukomp_api_v1 *api = (const zukomp_api_v1 *)table;
  *kind = "codec";
  if (api == NULL) {
    ArrowErrorSet(error, "zukomp's C table is unavailable");
    return ENOTSUP;
  }
  zu_codec id = zar_codec_id(codec);
  if (id == ZU_CODEC_NONE) {
    ArrowErrorSet(error, "unknown IPC compression codec %d", codec);
    return EINVAL;
  }
  if (!api->codec_available(id)) {
    ArrowErrorSet(error, "zukomp has no %s codec", id == ZU_CODEC_ZSTD ? "zstd" : "lz4-frame");
    return ENOTSUP;
  }
  zu_decoder_opts opts;
  memset(&opts, 0, sizeof(opts));
  opts.struct_size = (uint32_t)sizeof(opts);
  opts.codec = id;
  opts.max_output = (uint64_t)dst_size;
  opts.flags = ZU_DEC_EXPECTED_SIZE | ZU_DEC_REJECT_TRAILING;
  opts.expected_size = (uint64_t)dst_size;
  size_t written = 0;
  zu_status status =
      api->decompress_one(&opts, src, (size_t)src_size, dst, (size_t)dst_size, &written);
  if (status == ZU_ERR_OUTPUT_LIMIT || status == ZU_ERR_RATIO_LIMIT) {
    *kind = "limit";
    ArrowErrorSet(error, "a compressed buffer decodes past its declared %" PRId64 " bytes",
                  dst_size);
    return EINVAL;
  }
  if (status != ZU_OK && status != ZU_STREAM_END) {
    ArrowErrorSet(error, "%s decompression failed: %s",
                  id == ZU_CODEC_ZSTD ? "zstd" : "lz4-frame", api->status_string(status));
    return EINVAL;
  }
  if ((int64_t)written != dst_size) {
    *kind = "format";
    ArrowErrorSet(error, "a compressed buffer decodes to %ld bytes, not its declared %" PRId64,
                  (long)written, dst_size);
    return EINVAL;
  }
  return NANOARROW_OK;
}

/* Compresses `n` bytes into `dst` (of `cap` bytes) as an IPC body buffer.
   Sets *written; returns non-zero with `error` set on failure. */
int zar_codec_compress(const void *table, int codec, int level, const uint8_t *src,
                       int64_t n, uint8_t *dst, int64_t cap, int64_t *written,
                       struct ArrowError *error) {
  const zukomp_api_v1 *api = (const zukomp_api_v1 *)table;
  if (api == NULL) {
    ArrowErrorSet(error, "zukomp's C table is unavailable");
    return ENOTSUP;
  }
  zu_codec id = zar_codec_id(codec);
  zu_encoder_opts opts;
  memset(&opts, 0, sizeof(opts));
  opts.struct_size = (uint32_t)sizeof(opts);
  opts.codec = id;
  opts.level = level;
  size_t out = 0;
  zu_status status = api->compress_one(&opts, src, (size_t)n, dst, (size_t)cap, &out);
  if (status != ZU_OK && status != ZU_STREAM_END) {
    ArrowErrorSet(error, "%s compression failed: %s",
                  id == ZU_CODEC_ZSTD ? "zstd" : "lz4-frame", api->status_string(status));
    return EINVAL;
  }
  *written = (int64_t)out;
  return NANOARROW_OK;
}

int64_t zar_codec_bound(const void *table, int codec, int level, int64_t n) {
  const zukomp_api_v1 *api = (const zukomp_api_v1 *)table;
  size_t out = 0;
  if (api == NULL || api->compress_bound(zar_codec_id(codec), level, (size_t)n, &out) != ZU_OK) {
    return -1;
  }
  return (int64_t)out;
}

#endif /* ZAR_STANDALONE */
