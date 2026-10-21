/* Writing the Arrow IPC formats (design section 6.8): the schema, one
   dictionary batch per dictionary before the first record batch, the
   record batches, the end-of-stream marker and, for the file format, the
   footer. Bodies are padded to 8 bytes with zeros (D11); a compressed
   buffer carries its uncompressed length, or -1 when compressing does not
   shrink it. Message order, padding and the FlatBuffers are fixed, so the
   same input gives the same bytes on every platform. */
#include <inttypes.h>
#include <string.h>

#include "zar.h"
#include "nanoarrow_ipc.h"

const void *zar_codecs_api(void);
int zar_codec_compress(const void *table, int codec, int level, const uint8_t *src,
                       int64_t n, uint8_t *dst, int64_t cap, int64_t *written,
                       struct ArrowError *error);
int64_t zar_codec_bound(const void *table, int codec, int level, int64_t n);

/* ---- scratch, owned by an external pointer ----------------------------- */

struct zar_writer {
  struct ArrowIpcEncoder encoder;
  int encoder_ready;
  struct ArrowBuffer out;
  struct ArrowBuffer message;
  struct ArrowBuffer body;
  struct ArrowBuffer packed; /* one compressed buffer */
  struct ArrowArrayView view;
  int view_ready;
  struct ArrowIpcFooter footer;
  int footer_ready;
  struct ArrowArrayView **dict_views; /* the dictionaries last written, by id */
  int64_t n_dicts;
  const void *codecs;
  int codec;
  int level;
};

static void zar_writer_free(struct zar_writer *w) {
  if (w->encoder_ready) ArrowIpcEncoderReset(&w->encoder);
  ArrowBufferReset(&w->out);
  ArrowBufferReset(&w->message);
  ArrowBufferReset(&w->body);
  ArrowBufferReset(&w->packed);
  if (w->view_ready) ArrowArrayViewReset(&w->view);
  if (w->footer_ready) ArrowIpcFooterReset(&w->footer);
  free(w->dict_views);
}

static void zar_writer_finalize(SEXP xptr) {
  struct zar_writer *w = (struct zar_writer *)R_ExternalPtrAddr(xptr);
  if (w != NULL) {
    zar_writer_free(w);
    free(w);
    R_ClearExternalPtr(xptr);
  }
}

/* ---- buffers ---------------------------------------------------------- */

static int zar_pad8(struct ArrowBuffer *b) {
  int64_t pad = (8 - b->size_bytes % 8) % 8;
  return pad == 0 ? NANOARROW_OK : ArrowBufferAppendFill(b, 0, pad);
}

/* The body callback: each buffer 8-byte aligned and zero padded, compressed
   when a codec is set and compressing shrinks it. */
static ArrowErrorCode zar_encode_buffer(struct ArrowBufferView buffer, void *state,
                                        int64_t *offset, int64_t *length,
                                        int64_t *body_length, struct ArrowError *error) {
  struct zar_writer *w = (struct zar_writer *)state;
  struct ArrowBuffer *body = &w->body;
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(zar_pad8(body), error);
  *offset = body->size_bytes;
  if (buffer.size_bytes == 0) {
    *length = 0;
    *body_length = body->size_bytes;
    return NANOARROW_OK;
  }
  if (w->codec == NANOARROW_IPC_COMPRESSION_TYPE_NONE) {
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(
        ArrowBufferAppend(body, buffer.data.data, buffer.size_bytes), error);
    *length = buffer.size_bytes;
  } else {
    int64_t cap = zar_codec_bound(w->codecs, w->codec, w->level, buffer.size_bytes);
    if (cap < 0) {
      ArrowErrorSet(error, "the codec cannot bound a buffer of %" PRId64 " bytes",
                    buffer.size_bytes);
      return EINVAL;
    }
    w->packed.size_bytes = 0;
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferReserve(&w->packed, cap), error);
    int64_t written = 0;
    NANOARROW_RETURN_NOT_OK(zar_codec_compress(w->codecs, w->codec, w->level,
                                               buffer.data.as_uint8, buffer.size_bytes,
                                               w->packed.data, cap, &written, error));
    int64_t prefix;
    if (written < buffer.size_bytes) {
      prefix = buffer.size_bytes;
      NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferAppendInt64(body, prefix), error);
      NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferAppend(body, w->packed.data, written),
                                         error);
      *length = 8 + written;
    } else {
      /* Compressing did not shrink it: -1, then the bytes as they are. */
      prefix = -1;
      NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferAppendInt64(body, prefix), error);
      NANOARROW_RETURN_NOT_OK_WITH_ERROR(
          ArrowBufferAppend(body, buffer.data.data, buffer.size_bytes), error);
      *length = 8 + buffer.size_bytes;
    }
  }
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(zar_pad8(body), error);
  *body_length = body->size_bytes;
  return NANOARROW_OK;
}

/* Appends the message just encoded and its body to the output, recording
   its block for the footer when `blocks` is not NULL. */
static int zar_emit(struct zar_writer *w, struct ArrowBuffer *blocks,
                    struct ArrowError *error) {
  w->message.size_bytes = 0;
  NANOARROW_RETURN_NOT_OK(ArrowIpcEncoderFinalizeBuffer(&w->encoder, 1, &w->message));
  struct ArrowIpcFileBlock block;
  block.offset = w->out.size_bytes;
  block.metadata_length = (int32_t)w->message.size_bytes;
  block.body_length = w->body.size_bytes;
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowBufferAppend(&w->out, w->message.data, w->message.size_bytes), error);
  if (w->body.size_bytes > 0) {
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(
        ArrowBufferAppend(&w->out, w->body.data, w->body.size_bytes), error);
  }
  if (blocks != NULL) {
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferAppend(blocks, &block, sizeof(block)),
                                       error);
  }
  return NANOARROW_OK;
}

/* ---- dictionaries ----------------------------------------------------- */

/* Collects the dictionary views of a batch in the encoder's id order:
   a node's own dictionary, its children, then its dictionary's subtree. */
static int zar_collect_dicts(struct ArrowArrayView *view, struct ArrowArrayView **out,
                             int64_t cap, int64_t *n) {
  if (view->dictionary != NULL) {
    if (*n >= cap) return EINVAL;
    out[(*n)++] = view->dictionary;
  }
  for (int64_t i = 0; i < view->n_children; i++) {
    int code = zar_collect_dicts(view->children[i], out, cap, n);
    if (code != NANOARROW_OK) return code;
  }
  if (view->dictionary != NULL) return zar_collect_dicts(view->dictionary, out, cap, n);
  return NANOARROW_OK;
}

static int zar_count_dicts(const struct ArrowSchema *s) {
  int n = s->dictionary != NULL;
  for (int64_t i = 0; i < s->n_children; i++) n += zar_count_dicts(s->children[i]);
  if (s->dictionary != NULL) n += zar_count_dicts(s->dictionary);
  return n;
}

/* Writes one dictionary as a DictionaryBatch: its values are the one
   column of a struct view built around them. */
static int zar_write_dict(struct zar_writer *w, struct ArrowArrayView *values, int64_t id,
                          struct ArrowError *error) {
  struct ArrowArrayView wrap;
  ArrowArrayViewInitFromType(&wrap, NANOARROW_TYPE_STRUCT);
  int code = ArrowArrayViewAllocateChildren(&wrap, 1);
  if (code != NANOARROW_OK) {
    ArrowArrayViewReset(&wrap);
    ArrowErrorSet(error, "cannot allocate a dictionary batch");
    return code;
  }
  ArrowArrayViewReset(wrap.children[0]);
  ArrowFree(wrap.children[0]);
  wrap.children[0] = values;
  wrap.length = values->length;
  wrap.null_count = 0;
  w->body.size_bytes = 0;
  code = ArrowIpcEncoderEncodeBatch(&w->encoder, &wrap, &zar_encode_buffer, w,
                                    (enum ArrowIpcCompressionType)w->codec, id, 0, error);
  wrap.children[0] = NULL;
  ArrowArrayViewReset(&wrap);
  if (code != NANOARROW_OK) return code;
  return zar_emit(w, w->footer_ready ? &w->footer.dictionary_blocks : NULL, error);
}

/* ---- the entry point -------------------------------------------------- */

static SEXP zar_write_fail(const char *kind, struct ArrowError *error) {
  return zar_failure_from_error(kind, error);
}

/* Writes the batches in `arrays` (struct array handles of `schema`) as IPC
   bytes. `opts` is list(file, codec, level): file TRUE for the file format,
   codec 0 none, 1 lz4-frame, 2 zstd, level NA for the codec's default.
   Returns a raw vector. */
SEXP zar_c_write(SEXP arrays, SEXP schema_xptr, SEXP opts) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowSchema *schema = zar_schema_from_xptr(schema_xptr, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);
  int file = Rf_asLogical(VECTOR_ELT(opts, 0));
  int codec_code = Rf_asInteger(VECTOR_ELT(opts, 1));
  int level = Rf_asInteger(VECTOR_ELT(opts, 2));

  SEXP scratch = PROTECT(R_MakeExternalPtr(NULL, R_NilValue, R_NilValue));
  R_RegisterCFinalizer(scratch, &zar_writer_finalize);
  struct zar_writer *w = (struct zar_writer *)calloc(1, sizeof(struct zar_writer));
  if (w == NULL) {
    UNPROTECT(1);
    return zar_failure(NULL, "cannot allocate the writer");
  }
  R_SetExternalPtrAddr(scratch, w);
  ArrowBufferInit(&w->out);
  ArrowBufferInit(&w->message);
  ArrowBufferInit(&w->body);
  ArrowBufferInit(&w->packed);
  w->codecs = zar_codecs_api();
  w->codec = codec_code == 1   ? NANOARROW_IPC_COMPRESSION_TYPE_LZ4_FRAME
             : codec_code == 2 ? NANOARROW_IPC_COMPRESSION_TYPE_ZSTD
                               : NANOARROW_IPC_COMPRESSION_TYPE_NONE;
  w->level = level == NA_INTEGER ? INT32_MIN : level; /* ZU_LEVEL_DEFAULT */

  int code = ArrowIpcEncoderInit(&w->encoder);
  w->encoder_ready = code == NANOARROW_OK;
  const char *kind = NULL;
  if (code == NANOARROW_OK && file) {
    ArrowIpcFooterInit(&w->footer);
    w->footer_ready = 1;
    code = ArrowSchemaDeepCopy(schema, &w->footer.schema);
    if (code == NANOARROW_OK) {
      code = ArrowIpcDictionaryEncodingsAppendSchema(&w->footer.dictionaries,
                                                     &w->footer.schema);
    }
    if (code == NANOARROW_OK) code = ArrowBufferAppend(&w->out, "ARROW1\0\0", 8);
  }
  if (code == NANOARROW_OK) {
    code = ArrowIpcEncoderEncodeSchema(&w->encoder, schema, &error);
    w->body.size_bytes = 0;
    if (code == NANOARROW_OK) code = zar_emit(w, NULL, &error);
  }

  w->n_dicts = zar_count_dicts(schema);
  w->dict_views = (struct ArrowArrayView **)calloc(
      (size_t)(w->n_dicts > 0 ? w->n_dicts : 1), sizeof(struct ArrowArrayView *));
  struct ArrowArrayView **batch_dicts = (struct ArrowArrayView **)R_alloc(
      (size_t)(w->n_dicts > 0 ? w->n_dicts : 1), sizeof(struct ArrowArrayView *));
  /* The views of the last batch stay alive for the comparison: one view per
     batch, owned by R_alloc'ed storage and reset below. */
  struct ArrowArrayView *views = (struct ArrowArrayView *)R_alloc(
      (size_t)(Rf_xlength(arrays) > 0 ? Rf_xlength(arrays) : 1), sizeof(struct ArrowArrayView));
  R_xlen_t n_views = 0;

  for (R_xlen_t b = 0; code == NANOARROW_OK && b < Rf_xlength(arrays); b++) {
    struct ArrowArray *array = zar_array_from_xptr(VECTOR_ELT(arrays, b), &error);
    if (array == NULL) {
      code = EINVAL;
      kind = "handle";
      break;
    }
    struct ArrowArrayView *view = &views[n_views];
    code = ArrowArrayViewInitFromSchema(view, schema, &error);
    if (code != NANOARROW_OK) break;
    n_views++;
    code = ArrowArrayViewSetArray(view, array, &error);
    if (code != NANOARROW_OK) {
      kind = "format";
      break;
    }

    /* Dictionaries: written before the first batch, and again only when a
       stream's batch brings a different one. */
    int64_t n = 0;
    code = zar_collect_dicts(view, batch_dicts, w->n_dicts, &n);
    for (int64_t k = 0; code == NANOARROW_OK && k < n; k++) {
      int differs = w->dict_views[k] == NULL;
      if (!differs) {
        int equal = 0;
        struct ArrowError reason;
        code = ArrowArrayViewCompare(batch_dicts[k], w->dict_views[k],
                                     NANOARROW_COMPARE_IDENTICAL, &equal, &reason);
        differs = !equal;
      }
      if (code == NANOARROW_OK && differs) {
        if (file && w->dict_views[k] != NULL) {
          ArrowErrorSet(&error,
                        "dictionary %ld changes between batches, which the file "
                        "format cannot hold; write the stream format",
                        (long)k);
          kind = "type";
          code = EINVAL;
          break;
        }
        code = zar_write_dict(w, batch_dicts[k], k, &error);
        w->dict_views[k] = batch_dicts[k];
      }
    }
    if (code != NANOARROW_OK) break;

    w->body.size_bytes = 0;
    code = ArrowIpcEncoderEncodeBatch(&w->encoder, view, &zar_encode_buffer, w,
                                      (enum ArrowIpcCompressionType)w->codec, -1, 0, &error);
    if (code == NANOARROW_OK) {
      code = zar_emit(w, w->footer_ready ? &w->footer.record_batch_blocks : NULL, &error);
    }
  }

  /* The end-of-stream marker, which the file format carries too. */
  if (code == NANOARROW_OK) {
    uint32_t eos[2] = {0xFFFFFFFFu, 0};
    code = ArrowBufferAppend(&w->out, eos, sizeof(eos));
  }
  if (code == NANOARROW_OK && file) {
    w->message.size_bytes = 0;
    code = ArrowIpcEncoderEncodeFooter(&w->encoder, &w->footer, &error);
    if (code == NANOARROW_OK) {
      code = ArrowIpcEncoderFinalizeBuffer(&w->encoder, 0, &w->message);
    }
    if (code == NANOARROW_OK) {
      int32_t size = (int32_t)w->message.size_bytes;
      code = ArrowBufferAppend(&w->out, w->message.data, w->message.size_bytes);
      if (code == NANOARROW_OK) code = ArrowBufferAppend(&w->out, &size, sizeof(size));
      if (code == NANOARROW_OK) code = ArrowBufferAppend(&w->out, "ARROW1", 6);
    }
  }

  for (R_xlen_t k = 0; k < n_views; k++) ArrowArrayViewReset(&views[k]);
  if (code != NANOARROW_OK) {
    if (error.message[0] == '\0') ArrowErrorSet(&error, "the IPC output could not be written");
    SEXP fail = PROTECT(zar_write_fail(kind, &error));
    UNPROTECT(2);
    return fail;
  }
  SEXP out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)w->out.size_bytes));
  if (w->out.size_bytes > 0) memcpy(RAW(out), w->out.data, (size_t)w->out.size_bytes);
  UNPROTECT(2);
  return out;
}
