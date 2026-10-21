/* Reading the Arrow IPC formats (design section 6.7). The input is held in
   memory; the framing is detected from its first bytes; every message is
   verified and checked against the limits before its body is touched, and
   each decoded batch passes nanoarrow's full validation and zuarrow's UTF-8
   check before R sees it. The reader is an ArrowArrayStream, so arrow_read()
   with lazy = TRUE hands it out as a stream handle. */
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zar.h"
#include "nanoarrow_ipc.h"
#include "nanoarrow_ipc_flatcc_generated.h"

#define ns(x) FLATBUFFERS_WRAP_NAMESPACE(org_apache_arrow_flatbuf, x)

struct zar_limits {
  double max_message;
  double max_batch_rows;
  double max_bytes;
  int max_depth;
};

struct zar_reader {
  struct ArrowIpcDecoder decoder;
  struct ArrowIpcDecompressor decompressor;
  struct ArrowIpcDictionaryEncodings encodings;
  struct ArrowIpcDictionaries dictionaries;
  struct ArrowSchema schema;     /* the input's schema */
  struct ArrowSchema out_schema; /* the selected columns */
  int dictionaries_ready;
  int encodings_ready;

  uint8_t *data;
  int64_t size;
  int64_t pos;     /* the stream cursor */
  int is_file;
  int started;     /* a batch has been read: the selection is fixed */
  int ended;
  int64_t block;   /* the next record batch block of a file */
  int64_t n_blocks;
  struct ArrowIpcFileBlock *blocks;
  int64_t n_dict_blocks;
  struct ArrowIpcFileBlock *dict_blocks;
  int64_t *seen_ids; /* dictionary ids a file has defined */
  int64_t n_seen;

  int64_t n_select; /* -1: every column */
  int64_t *select;  /* top-level field indices, in output order */
  int64_t *field_index; /* the decoder's index of each top-level field */

  struct zar_limits limits;
  struct ArrowError error;
  const char *kind; /* the condition kind of the last failure */
  const void *codecs; /* zukomp's C table */
};

static int zar_reader_fail(struct zar_reader *r, const char *kind, int code) {
  r->kind = kind;
  return code == 0 ? EINVAL : code;
}

/* ---- the decompressor: zar_codecs.c drives zukomp ----------------------- */

const void *zar_codecs_api(void);
int zar_codec_decompress(const void *table, int codec, const uint8_t *src,
                         int64_t src_size, uint8_t *dst, int64_t dst_size,
                         struct ArrowError *error, const char **kind);

static ArrowErrorCode zar_decompress_add(struct ArrowIpcDecompressor *d,
                                         enum ArrowIpcCompressionType type,
                                         struct ArrowBufferView src, uint8_t *dst,
                                         int64_t dst_size, struct ArrowError *error) {
  struct zar_reader *r = (struct zar_reader *)d->private_data;
  const char *kind = NULL;
  int code = zar_codec_decompress(r->codecs, (int)type, src.data.as_uint8, src.size_bytes,
                                  dst, dst_size, error, &kind);
  if (code != NANOARROW_OK) r->kind = kind;
  return code;
}

static ArrowErrorCode zar_decompress_wait(struct ArrowIpcDecompressor *d,
                                          int64_t timeout_ms, struct ArrowError *error) {
  NANOARROW_UNUSED(d);
  NANOARROW_UNUSED(timeout_ms);
  NANOARROW_UNUSED(error);
  return NANOARROW_OK;
}

static void zar_decompress_release(struct ArrowIpcDecompressor *d) {
  d->release = NULL;
}

/* ---- lifetime --------------------------------------------------------- */

static void zar_reader_free(struct zar_reader *r) {
  if (r == NULL) return;
  ArrowIpcDecoderReset(&r->decoder);
  if (r->dictionaries_ready) ArrowIpcDictionariesReset(&r->dictionaries);
  if (r->encodings_ready) ArrowIpcDictionaryEncodingsReset(&r->encodings);
  if (r->schema.release != NULL) r->schema.release(&r->schema);
  if (r->out_schema.release != NULL) r->out_schema.release(&r->out_schema);
  free(r->data);
  free(r->blocks);
  free(r->dict_blocks);
  free(r->seen_ids);
  free(r->select);
  free(r->field_index);
  free(r);
}

/* ---- schema checks ---------------------------------------------------- */

static int zar_schema_depth(const struct ArrowSchema *s) {
  int depth = 0;
  for (int64_t i = 0; i < s->n_children; i++) {
    int d = zar_schema_depth(s->children[i]);
    if (d > depth) depth = d;
  }
  if (s->dictionary != NULL) {
    int d = zar_schema_depth(s->dictionary);
    if (d > depth) depth = d;
  }
  return depth + 1;
}

static int64_t zar_count_fields(const struct ArrowSchema *s) {
  int64_t n = 1;
  for (int64_t i = 0; i < s->n_children; i++) n += zar_count_fields(s->children[i]);
  return n;
}

/* After the schema: the depth limit, little-endian only (D13), the
   decoder set up for batches and the dictionaries for their values. */
static int zar_reader_set_schema(struct zar_reader *r) {
  if (r->decoder.endianness == NANOARROW_IPC_ENDIANNESS_BIG) {
    ArrowErrorSet(&r->error, "the input is big-endian; zuarrow reads little-endian only");
    return zar_reader_fail(r, "format", EINVAL);
  }
  if (zar_schema_depth(&r->schema) - 1 > r->limits.max_depth) {
    ArrowErrorSet(&r->error, "the schema nests deeper than max_depth (%d)",
                  r->limits.max_depth);
    return zar_reader_fail(r, "limit", EINVAL);
  }
  int code = ArrowIpcDecoderSetSchemaWithDictionaries(&r->decoder, &r->schema,
                                                      &r->encodings, &r->error);
  if (code != NANOARROW_OK) return zar_reader_fail(r, code == ENOTSUP ? "format" : "format", code);
  code = ArrowIpcDictionariesInit(&r->dictionaries, &r->encodings, &r->error);
  if (code != NANOARROW_OK) return zar_reader_fail(r, "format", code);
  r->dictionaries_ready = 1;

  int64_t n = r->schema.n_children;
  r->field_index = (int64_t *)calloc(n > 0 ? (size_t)n : 1, sizeof(int64_t));
  if (r->field_index == NULL) {
    ArrowErrorSet(&r->error, "cannot allocate the reader");
    return zar_reader_fail(r, NULL, ENOMEM);
  }
  int64_t at = 0;
  for (int64_t i = 0; i < n; i++) {
    r->field_index[i] = at;
    at += zar_count_fields(r->schema.children[i]);
  }
  return ArrowSchemaDeepCopy(&r->schema, &r->out_schema) == NANOARROW_OK
             ? NANOARROW_OK
             : zar_reader_fail(r, NULL, ENOMEM);
}

/* ---- messages --------------------------------------------------------- */

/* Verifies and decodes the message at `pos`, which must lie inside the
   input with its body, and leaves `*body` on the body. Returns ENODATA at
   an end-of-stream marker. */
static int zar_read_message(struct zar_reader *r, int64_t pos,
                            struct ArrowBufferView *header,
                            struct ArrowBufferView *body) {
  if (pos < 0 || pos > r->size) {
    ArrowErrorSet(&r->error, "a message starts outside the input");
    return zar_reader_fail(r, "format", EINVAL);
  }
  struct ArrowBufferView view = {{r->data + pos}, r->size - pos};
  int32_t prefix = 0;
  int code = ArrowIpcDecoderPeekHeader(&r->decoder, view, &prefix, &r->error);
  if (code == ENODATA) return ENODATA;
  if (code != NANOARROW_OK) return zar_reader_fail(r, "format", code);

  int64_t header_size = r->decoder.header_size_bytes;
  if ((double)header_size > r->limits.max_message) {
    ArrowErrorSet(&r->error, "a message header of %" PRId64 " bytes is over max_message",
                  header_size);
    return zar_reader_fail(r, "limit", EINVAL);
  }
  if (header_size > view.size_bytes) {
    ArrowErrorSet(&r->error, "a message header runs past the end of the input");
    return zar_reader_fail(r, "format", EINVAL);
  }
  view.size_bytes = header_size;
  code = ArrowIpcDecoderVerifyHeader(&r->decoder, view, &r->error);
  if (code != NANOARROW_OK) return zar_reader_fail(r, "format", code);
  code = ArrowIpcDecoderDecodeHeader(&r->decoder, view, &r->error);
  if (code != NANOARROW_OK) return zar_reader_fail(r, "format", code);

  int64_t body_size = r->decoder.body_size_bytes;
  if (body_size < 0 || (double)body_size > r->limits.max_message) {
    ArrowErrorSet(&r->error, "a message body of %" PRId64 " bytes is over max_message",
                  body_size);
    return zar_reader_fail(r, "limit", EINVAL);
  }
  if (body_size > r->size - pos - header_size) {
    ArrowErrorSet(&r->error, "a message body runs past the end of the input");
    return zar_reader_fail(r, "format", EINVAL);
  }
  *header = view;
  header->data.as_uint8 += prefix;
  header->size_bytes -= prefix;
  body->data.as_uint8 = r->data + pos + header_size;
  body->size_bytes = body_size;
  return NANOARROW_OK;
}

/* Checks a record batch before decoding (the check-then-build rule of
   section 6.7): the row count, every buffer inside the body, and every
   compressed buffer's length prefix under max_message, so a lying prefix
   is a limit error before anything is allocated for it. */
static int zar_check_record_batch(struct zar_reader *r, ns(RecordBatch_table_t) batch,
                                  struct ArrowBufferView body) {
  if (batch == NULL) {
    ArrowErrorSet(&r->error, "a message has no record batch");
    return zar_reader_fail(r, "format", EINVAL);
  }
  int64_t length = ns(RecordBatch_length(batch));
  if (length < 0 || (double)length > r->limits.max_batch_rows) {
    ArrowErrorSet(&r->error, "a batch of %" PRId64 " rows is over max_batch_rows", length);
    return zar_reader_fail(r, length < 0 ? "format" : "limit", EINVAL);
  }
  int compressed = ns(RecordBatch_compression_is_present(batch));
  ns(Buffer_vec_t) buffers = ns(RecordBatch_buffers(batch));
  size_t n = ns(Buffer_vec_len(buffers));
  for (size_t i = 0; i < n; i++) {
    ns(Buffer_struct_t) b = ns(Buffer_vec_at(buffers, i));
    int64_t offset = ns(Buffer_offset(b));
    int64_t size = ns(Buffer_length(b));
    if (offset < 0 || size < 0 || offset > body.size_bytes ||
        size > body.size_bytes - offset) {
      ArrowErrorSet(&r->error, "buffer %ld lies outside its message body", (long)i);
      return zar_reader_fail(r, "format", EINVAL);
    }
    if (compressed && size >= 8) {
      int64_t prefix;
      memcpy(&prefix, body.data.as_uint8 + offset, sizeof(prefix));
      if (prefix != -1 && (prefix < 0 || (double)prefix > r->limits.max_message)) {
        ArrowErrorSet(&r->error,
                      "buffer %ld claims %" PRId64 " uncompressed bytes, over max_message",
                      (long)i, prefix);
        return zar_reader_fail(r, prefix < 0 ? "format" : "limit", EINVAL);
      }
    }
  }
  return NANOARROW_OK;
}

static int zar_check_batch(struct zar_reader *r, struct ArrowBufferView header,
                           struct ArrowBufferView body) {
  ns(Message_table_t) message = ns(Message_as_root(header.data.data));
  return zar_check_record_batch(
      r, (ns(RecordBatch_table_t))ns(Message_header(message)), body);
}

static int zar_apply_dictionary(struct zar_reader *r, struct ArrowBufferView header,
                                struct ArrowBufferView body) {
  ns(Message_table_t) message = ns(Message_as_root(header.data.data));
  ns(DictionaryBatch_table_t) dictionary =
      (ns(DictionaryBatch_table_t))ns(Message_header(message));
  int checked = zar_check_record_batch(r, ns(DictionaryBatch_data(dictionary)), body);
  if (checked != NANOARROW_OK) return checked;
  r->kind = NULL;
  const struct ArrowIpcDictionaryBatch *d = r->decoder.dictionary;
  if (r->is_file && d != NULL) {
    /* A file may define a dictionary once and extend it, never replace it. */
    int seen = 0;
    for (int64_t k = 0; k < r->n_seen; k++) seen |= r->seen_ids[k] == d->id;
    if (seen && !d->is_delta) {
      ArrowErrorSet(&r->error, "the file replaces dictionary %" PRId64 ", which the format forbids",
                    d->id);
      return zar_reader_fail(r, "format", EINVAL);
    }
    if (!seen) {
      int64_t *ids = (int64_t *)realloc(r->seen_ids, (size_t)(r->n_seen + 1) * sizeof(int64_t));
      if (ids == NULL) return zar_reader_fail(r, NULL, ENOMEM);
      r->seen_ids = ids;
      r->seen_ids[r->n_seen++] = d->id;
    }
  }
  int code = ArrowIpcDecoderDecodeDictionary(&r->decoder, body, NANOARROW_VALIDATION_LEVEL_FULL,
                                             &r->dictionaries, &r->error);
  if (code != NANOARROW_OK && r->kind == NULL) r->kind = "format";
  return code;
}

/* A struct array of `n` children, each to be filled by the decoder, with
   no validity buffer. It is built by hand, not through nanoarrow's
   builder, so finishing never walks the decoder's shared dictionaries. */
struct zar_struct_private {
  const void *buffers[1];
  struct ArrowArray **children;
  int64_t n;
};

static void zar_struct_release(struct ArrowArray *array) {
  struct zar_struct_private *p = (struct zar_struct_private *)array->private_data;
  for (int64_t k = 0; k < p->n; k++) {
    if (p->children[k]->release != NULL) p->children[k]->release(p->children[k]);
    free(p->children[k]);
  }
  free(p->children);
  free(p);
  array->release = NULL;
}

static int zar_struct_init(struct ArrowArray *out, int64_t n, int64_t length) {
  struct zar_struct_private *p =
      (struct zar_struct_private *)calloc(1, sizeof(struct zar_struct_private));
  if (p == NULL) return ENOMEM;
  p->children = (struct ArrowArray **)calloc(n > 0 ? (size_t)n : 1, sizeof(struct ArrowArray *));
  if (p->children == NULL) {
    free(p);
    return ENOMEM;
  }
  for (int64_t k = 0; k < n; k++) {
    p->children[k] = (struct ArrowArray *)calloc(1, sizeof(struct ArrowArray));
    if (p->children[k] == NULL) {
      p->n = k;
      out->private_data = p;
      zar_struct_release(out);
      return ENOMEM;
    }
  }
  p->n = n;
  out->length = length;
  out->null_count = 0;
  out->offset = 0;
  out->n_buffers = 1;
  out->n_children = n;
  out->buffers = p->buffers;
  out->children = p->children;
  out->dictionary = NULL;
  out->release = &zar_struct_release;
  out->private_data = p;
  return NANOARROW_OK;
}

/* Decodes the record batch whose header was just read into `out`, as the
   selected columns, fully validated. */
static int zar_decode_batch(struct zar_reader *r, struct ArrowBufferView header,
                            struct ArrowBufferView body, struct ArrowArray *out) {
  int code = zar_check_batch(r, header, body);
  if (code != NANOARROW_OK) return code;
  r->kind = NULL;
  if (r->n_select < 0) {
    code = ArrowIpcDecoderDecodeArrayWithDictionaries(
        &r->decoder, body, -1, &r->dictionaries, out, NANOARROW_VALIDATION_LEVEL_FULL,
        &r->error);
  } else {
    ns(Message_table_t) message = ns(Message_as_root(header.data.data));
    ns(RecordBatch_table_t) batch = (ns(RecordBatch_table_t))ns(Message_header(message));
    code = zar_struct_init(out, r->n_select, ns(RecordBatch_length(batch)));
    if (code != NANOARROW_OK) ArrowErrorSet(&r->error, "cannot allocate a batch");
    for (int64_t k = 0; code == NANOARROW_OK && k < r->n_select; k++) {
      code = ArrowIpcDecoderDecodeArrayWithDictionaries(
          &r->decoder, body, r->field_index[r->select[k]], &r->dictionaries,
          out->children[k], NANOARROW_VALIDATION_LEVEL_FULL, &r->error);
    }
    if (code != NANOARROW_OK && out->release != NULL) out->release(out);
  }
  if (code != NANOARROW_OK) {
    if (r->kind == NULL) r->kind = "format";
    return code;
  }

  /* nanoarrow's full level does not read string contents (section 6.11). */
  struct ArrowArrayView view;
  code = ArrowArrayViewInitFromSchema(&view, &r->out_schema, &r->error);
  if (code == NANOARROW_OK) code = ArrowArrayViewSetArray(&view, out, &r->error);
  if (code == NANOARROW_OK) code = zar_view_validate_utf8(&view, "", &r->error);
  ArrowArrayViewReset(&view);
  if (code != NANOARROW_OK) {
    out->release(out);
    return zar_reader_fail(r, "format", code);
  }
  return NANOARROW_OK;
}

/* ---- the two framings ------------------------------------------------- */

static int zar_open_stream(struct zar_reader *r) {
  struct ArrowBufferView header, body;
  int code = zar_read_message(r, 0, &header, &body);
  if (code == ENODATA) {
    ArrowErrorSet(&r->error, "the stream ends before its schema");
    return zar_reader_fail(r, "format", EINVAL);
  }
  if (code != NANOARROW_OK) return code;
  if (r->decoder.message_type != NANOARROW_IPC_MESSAGE_TYPE_SCHEMA) {
    ArrowErrorSet(&r->error, "the stream does not start with a schema");
    return zar_reader_fail(r, "format", EINVAL);
  }
  code = ArrowIpcDecoderDecodeSchemaWithDictionaries(&r->decoder, &r->schema, &r->encodings,
                                                     &r->error);
  if (code != NANOARROW_OK) return zar_reader_fail(r, "format", code);
  r->encodings_ready = 1;
  r->pos = (int64_t)(body.data.as_uint8 - r->data) + body.size_bytes;
  return zar_reader_set_schema(r);
}

static int zar_open_file(struct zar_reader *r) {
  /* The footer gives the blocks. */
  struct ArrowBufferView all = {{r->data}, r->size};
  int code = ArrowIpcDecoderVerifyFooter(&r->decoder, all, &r->error);
  if (code != NANOARROW_OK) return zar_reader_fail(r, "format", code);
  if ((double)r->decoder.header_size_bytes > r->limits.max_message) {
    ArrowErrorSet(&r->error, "the footer is over max_message");
    return zar_reader_fail(r, "limit", EINVAL);
  }
  code = ArrowIpcDecoderDecodeFooter(&r->decoder, all, &r->error);
  if (code != NANOARROW_OK) return zar_reader_fail(r, "format", code);
  struct ArrowIpcFooter *footer = r->decoder.footer;
  r->n_blocks = footer->record_batch_blocks.size_bytes / (int64_t)sizeof(struct ArrowIpcFileBlock);
  r->n_dict_blocks = footer->dictionary_blocks.size_bytes / (int64_t)sizeof(struct ArrowIpcFileBlock);
  r->blocks = (struct ArrowIpcFileBlock *)malloc(
      (size_t)(r->n_blocks > 0 ? r->n_blocks : 1) * sizeof(struct ArrowIpcFileBlock));
  r->dict_blocks = (struct ArrowIpcFileBlock *)malloc(
      (size_t)(r->n_dict_blocks > 0 ? r->n_dict_blocks : 1) * sizeof(struct ArrowIpcFileBlock));
  if (r->blocks == NULL || r->dict_blocks == NULL) return zar_reader_fail(r, NULL, ENOMEM);
  if (r->n_blocks > 0) {
    memcpy(r->blocks, footer->record_batch_blocks.data,
           (size_t)r->n_blocks * sizeof(struct ArrowIpcFileBlock));
  }
  if (r->n_dict_blocks > 0) {
    memcpy(r->dict_blocks, footer->dictionary_blocks.data,
           (size_t)r->n_dict_blocks * sizeof(struct ArrowIpcFileBlock));
  }

  /* The schema message after the magic gives the schema, its dictionary
     ids and its endianness. */
  struct ArrowBufferView header, body;
  code = zar_read_message(r, 8, &header, &body);
  if (code == ENODATA ||
      (code == NANOARROW_OK && r->decoder.message_type != NANOARROW_IPC_MESSAGE_TYPE_SCHEMA)) {
    ArrowErrorSet(&r->error, "the file does not start with a schema");
    return zar_reader_fail(r, "format", EINVAL);
  }
  if (code != NANOARROW_OK) return code;
  code = ArrowIpcDecoderDecodeSchemaWithDictionaries(&r->decoder, &r->schema, &r->encodings,
                                                     &r->error);
  if (code != NANOARROW_OK) return zar_reader_fail(r, "format", code);
  r->encodings_ready = 1;
  code = zar_reader_set_schema(r);
  if (code != NANOARROW_OK) return code;

  /* Every dictionary in the footer, before the first batch. */
  for (int64_t k = 0; k < r->n_dict_blocks; k++) {
    struct ArrowIpcFileBlock *b = &r->dict_blocks[k];
    code = zar_read_message(r, b->offset, &header, &body);
    if (code == ENODATA || (code == NANOARROW_OK &&
                            r->decoder.message_type != NANOARROW_IPC_MESSAGE_TYPE_DICTIONARY_BATCH)) {
      ArrowErrorSet(&r->error, "dictionary block %ld is not a dictionary batch", (long)k);
      return zar_reader_fail(r, "format", EINVAL);
    }
    if (code != NANOARROW_OK) return code;
    code = zar_apply_dictionary(r, header, body);
    if (code != NANOARROW_OK) return code;
  }
  return NANOARROW_OK;
}

/* The next batch into `out`; out->release stays NULL at the end. */
static int zar_reader_next(struct zar_reader *r, struct ArrowArray *out) {
  out->release = NULL;
  if (r->ended) return NANOARROW_OK;
  r->started = 1;
  struct ArrowBufferView header, body;
  if (r->is_file) {
    if (r->block >= r->n_blocks) {
      r->ended = 1;
      return NANOARROW_OK;
    }
    struct ArrowIpcFileBlock *b = &r->blocks[r->block++];
    int code = zar_read_message(r, b->offset, &header, &body);
    if (code == ENODATA ||
        (code == NANOARROW_OK && r->decoder.message_type != NANOARROW_IPC_MESSAGE_TYPE_RECORD_BATCH)) {
      ArrowErrorSet(&r->error, "record batch block %ld is not a record batch", (long)(r->block - 1));
      return zar_reader_fail(r, "format", EINVAL);
    }
    if (code != NANOARROW_OK) return code;
    return zar_decode_batch(r, header, body, out);
  }
  for (;;) {
    if (r->pos >= r->size) {
      r->ended = 1;
      return NANOARROW_OK;
    }
    int code = zar_read_message(r, r->pos, &header, &body);
    if (code == ENODATA) {
      r->ended = 1;
      return NANOARROW_OK;
    }
    if (code != NANOARROW_OK) return code;
    r->pos = (int64_t)(body.data.as_uint8 - r->data) + body.size_bytes;
    switch (r->decoder.message_type) {
      case NANOARROW_IPC_MESSAGE_TYPE_DICTIONARY_BATCH:
        code = zar_apply_dictionary(r, header, body);
        if (code != NANOARROW_OK) return code;
        continue;
      case NANOARROW_IPC_MESSAGE_TYPE_RECORD_BATCH:
        return zar_decode_batch(r, header, body, out);
      default:
        ArrowErrorSet(&r->error, "a stream message is neither a batch nor a dictionary");
        return zar_reader_fail(r, "format", EINVAL);
    }
  }
}

/* ---- the ArrowArrayStream -------------------------------------------- */

static int zar_stream_get_schema(struct ArrowArrayStream *stream, struct ArrowSchema *out) {
  struct zar_reader *r = (struct zar_reader *)stream->private_data;
  return ArrowSchemaDeepCopy(&r->out_schema, out);
}

static int zar_stream_get_next(struct ArrowArrayStream *stream, struct ArrowArray *out) {
  struct zar_reader *r = (struct zar_reader *)stream->private_data;
  r->kind = NULL;
  ArrowErrorInit(&r->error);
  return zar_reader_next(r, out);
}

static const char *zar_stream_last_error(struct ArrowArrayStream *stream) {
  struct zar_reader *r = (struct zar_reader *)stream->private_data;
  return r->error.message;
}

static void zar_stream_release(struct ArrowArrayStream *stream) {
  zar_reader_free((struct zar_reader *)stream->private_data);
  stream->private_data = NULL;
  stream->release = NULL;
}

/* The kind of the last failure of a reader stream, or NULL when the stream
   is not one zuarrow's reader made. */
const char *zar_reader_kind(const struct ArrowArrayStream *stream) {
  if (stream->get_next != &zar_stream_get_next) return NULL;
  const struct zar_reader *r = (const struct zar_reader *)stream->private_data;
  return r->kind == NULL ? "format" : r->kind;
}

/* ---- R entry points --------------------------------------------------- */

static int zar_read_path(const char *path, uint8_t **out, int64_t *size,
                         double max_bytes, struct ArrowError *error, const char **kind) {
  FILE *f = fopen(path, "rb");
  if (f == NULL) {
    ArrowErrorSet(error, "cannot open '%s': %s", path, strerror(errno));
    *kind = "io";
    return EIO;
  }
  long n = -1;
  if (fseek(f, 0, SEEK_END) == 0) n = ftell(f);
  if (n < 0 || fseek(f, 0, SEEK_SET) != 0) {
    fclose(f);
    ArrowErrorSet(error, "cannot find the size of '%s'", path);
    *kind = "io";
    return EIO;
  }
  if ((double)n > max_bytes) {
    fclose(f);
    ArrowErrorSet(error, "'%s' is larger than max_bytes", path);
    *kind = "limit";
    return EINVAL;
  }
  uint8_t *buf = (uint8_t *)malloc(n > 0 ? (size_t)n : 1);
  if (buf == NULL) {
    fclose(f);
    ArrowErrorSet(error, "cannot allocate memory to read '%s'", path);
    *kind = NULL;
    return ENOMEM;
  }
  size_t got = n > 0 ? fread(buf, 1, (size_t)n, f) : 0;
  fclose(f);
  if ((long)got != n) {
    free(buf);
    ArrowErrorSet(error, "cannot read '%s'", path);
    *kind = "io";
    return EIO;
  }
  *out = buf;
  *size = (int64_t)n;
  return NANOARROW_OK;
}

/* Opens a reader over a path (a string) or bytes (a raw vector) and returns
   it as a stream handle. `limits` is c(max_message, max_depth,
   max_batch_rows, max_bytes). */
SEXP zar_c_reader_open(SEXP source, SEXP limits) {
  struct zar_reader *r = (struct zar_reader *)calloc(1, sizeof(struct zar_reader));
  if (r == NULL) return zar_failure(NULL, "cannot allocate the reader");
  r->n_select = -1;
  r->codecs = zar_codecs_api();
  r->limits.max_message = REAL(limits)[0];
  r->limits.max_depth = (int)REAL(limits)[1];
  r->limits.max_batch_rows = REAL(limits)[2];
  r->limits.max_bytes = REAL(limits)[3];

  int code = NANOARROW_OK;
  if (TYPEOF(source) == RAWSXP) {
    r->size = (int64_t)Rf_xlength(source);
    if ((double)r->size > r->limits.max_bytes) {
      ArrowErrorSet(&r->error, "the input is larger than max_bytes");
      r->kind = "limit";
      code = EINVAL;
    } else {
      r->data = (uint8_t *)malloc(r->size > 0 ? (size_t)r->size : 1);
      if (r->data == NULL) {
        code = ENOMEM;
        ArrowErrorSet(&r->error, "cannot allocate the input");
      } else if (r->size > 0) {
        memcpy(r->data, RAW(source), (size_t)r->size);
      }
    }
  } else {
    const char *path = R_ExpandFileName(Rf_translateChar(STRING_ELT(source, 0)));
    code = zar_read_path(path, &r->data, &r->size, r->limits.max_bytes, &r->error, &r->kind);
  }

  if (code == NANOARROW_OK) {
    code = ArrowIpcDecoderInit(&r->decoder);
    if (code != NANOARROW_OK) ArrowErrorSet(&r->error, "cannot allocate the decoder");
  }
  if (code == NANOARROW_OK) {
    r->decompressor.decompress_add = &zar_decompress_add;
    r->decompressor.decompress_wait = &zar_decompress_wait;
    r->decompressor.release = &zar_decompress_release;
    r->decompressor.private_data = r;
    code = ArrowIpcDecoderSetDecompressor(&r->decoder, &r->decompressor);
  }
  if (code == NANOARROW_OK) {
    r->is_file = r->size >= 8 && memcmp(r->data, "ARROW1", 6) == 0;
    code = r->is_file ? zar_open_file(r) : zar_open_stream(r);
  }
  if (code != NANOARROW_OK) {
    SEXP fail = PROTECT(zar_failure(r->kind, r->error.message[0] ? r->error.message
                                                                : "the input could not be read"));
    zar_reader_free(r);
    UNPROTECT(1);
    return fail;
  }

  SEXP out = PROTECT(zar_stream_owning_xptr());
  struct ArrowArrayStream *stream = (struct ArrowArrayStream *)R_ExternalPtrAddr(out);
  stream->get_schema = &zar_stream_get_schema;
  stream->get_next = &zar_stream_get_next;
  stream->get_last_error = &zar_stream_last_error;
  stream->release = &zar_stream_release;
  stream->private_data = r;
  UNPROTECT(1);
  return out;
}

/* Selects top-level columns by 0-based index, before the first batch. */
SEXP zar_c_reader_select(SEXP stream_xptr, SEXP columns) {
  struct ArrowError error;
  struct ArrowArrayStream *stream = zar_stream_from_xptr(stream_xptr, &error);
  if (stream == NULL) return zar_failure_from_error("handle", &error);
  if (stream->get_next != &zar_stream_get_next) {
    return zar_failure("handle", "only a stream from arrow_read() selects columns");
  }
  struct zar_reader *r = (struct zar_reader *)stream->private_data;
  if (r->started) return zar_failure("handle", "columns are selected before the first batch");
  R_xlen_t n = Rf_xlength(columns);
  int64_t *select = (int64_t *)malloc(n > 0 ? (size_t)n * sizeof(int64_t) : sizeof(int64_t));
  if (select == NULL) return zar_failure(NULL, "cannot allocate the selection");
  for (R_xlen_t k = 0; k < n; k++) {
    int idx = INTEGER(columns)[k];
    if (idx < 0 || idx >= r->schema.n_children) {
      free(select);
      return zar_failure("type", "a selected column is out of range");
    }
    select[k] = idx;
  }
  /* The output schema: the selected fields, in order. */
  struct ArrowSchema out;
  ArrowSchemaInit(&out);
  int code = ArrowSchemaSetFormat(&out, "+s");
  if (code == NANOARROW_OK) code = ArrowSchemaSetMetadata(&out, r->schema.metadata);
  if (code == NANOARROW_OK) code = ArrowSchemaAllocateChildren(&out, (int64_t)n);
  for (R_xlen_t k = 0; code == NANOARROW_OK && k < n; k++) {
    code = ArrowSchemaDeepCopy(r->schema.children[select[k]], out.children[k]);
  }
  if (code != NANOARROW_OK) {
    free(select);
    out.release(&out);
    return zar_failure(NULL, "cannot allocate the selected schema");
  }
  out.flags = r->schema.flags;
  free(r->select);
  r->select = select;
  r->n_select = (int64_t)n;
  r->out_schema.release(&r->out_schema);
  ArrowSchemaMove(&out, &r->out_schema);
  return Rf_ScalarLogical(TRUE);
}
