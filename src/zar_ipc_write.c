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
  const char *kind; /* the condition kind of a failure inside the callback */
  struct ArrowArray *copies; /* unsliced copies of sliced batches, by batch */
  int64_t n_copies;
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
  for (int64_t i = 0; i < w->n_copies; i++) {
    if (w->copies[i].release != NULL) ArrowArrayRelease(&w->copies[i]);
  }
  free(w->copies);
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
      w->kind = "codec";
      return EINVAL;
    }
    w->packed.size_bytes = 0;
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferReserve(&w->packed, cap), error);
    int64_t written = 0;
    int code = zar_codec_compress(w->codecs, w->codec, w->level, buffer.data.as_uint8,
                                  buffer.size_bytes, w->packed.data, cap, &written, error);
    if (code != NANOARROW_OK) {
      w->kind = zar_code_kind(code, "codec");
      return code;
    }
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

/* The C Data Interface allows an unknown null count (-1); a FieldNode
   needs the count. Computes it for every node of a view, dictionaries
   included, before the view is encoded. */
static void zar_fill_null_counts(struct ArrowArrayView *view) {
  if (view->null_count < 0) view->null_count = ArrowArrayViewComputeNullCount(view);
  for (int64_t i = 0; i < view->n_children; i++) zar_fill_null_counts(view->children[i]);
  if (view->dictionary != NULL) zar_fill_null_counts(view->dictionary);
}

/* ---- types the writer refuses ----------------------------------------- */

/* The view layouts have no IPC encoding in the vendored encoder, and no R
   source type writes them (section 2). Returns 0 and fills `error` for
   the first such field. */
static int zar_check_writable(const struct ArrowSchema *schema, struct ArrowError *error) {
  struct ArrowSchemaView sv;
  if (ArrowSchemaViewInit(&sv, schema, error) != NANOARROW_OK) return 0;
  switch (sv.type) {
    case NANOARROW_TYPE_STRING_VIEW:
    case NANOARROW_TYPE_BINARY_VIEW:
    case NANOARROW_TYPE_LIST_VIEW:
    case NANOARROW_TYPE_LARGE_LIST_VIEW:
      ArrowErrorSet(error, "field `%s` has the view layout `%s`, which cannot be written",
                    schema->name == NULL ? "" : schema->name, schema->format);
      return 0;
    default:
      break;
  }
  for (int64_t i = 0; i < schema->n_children; i++) {
    if (!zar_check_writable(schema->children[i], error)) return 0;
  }
  if (schema->dictionary != NULL && !zar_check_writable(schema->dictionary, error)) {
    return 0;
  }
  return 1;
}

/* ---- sliced batches --------------------------------------------------- */

/* Whether any node of a view, dictionaries included, has an offset. The
   IPC body has no offsets, so such a batch is copied before encoding. */
static int zar_has_offset(const struct ArrowArrayView *view) {
  if (view->offset != 0) return 1;
  for (int64_t i = 0; i < view->n_children; i++) {
    if (zar_has_offset(view->children[i])) return 1;
  }
  return view->dictionary != NULL && zar_has_offset(view->dictionary);
}

/* Whether a batch's view needs copying before encoding: a node has an
   offset, or a column is longer than the batch, as a zero-offset slice of
   a struct is. Each column's field node must hold the batch's length, so
   the copy cuts the columns to it (#206). */
static int zar_needs_copy(const struct ArrowArrayView *view) {
  for (int64_t i = 0; i < view->n_children; i++) {
    if (view->children[i]->length != view->length) return 1;
  }
  return zar_has_offset(view);
}

/* Appends bits [from, from + n) of `bits` to `dst` from bit zero, and
   counts the zeros when `zeros` is not NULL. */
static int zar_copy_bits(struct ArrowBuffer *dst, const uint8_t *bits, int64_t from,
                         int64_t n, int64_t *zeros) {
  NANOARROW_RETURN_NOT_OK(ArrowBufferAppendFill(dst, 0, (n + 7) / 8));
  int64_t count = 0;
  for (int64_t i = 0; i < n; i++) {
    int8_t bit = ArrowBitGet(bits, from + i);
    count += !bit;
    if (bit) ArrowBitSet(dst->data, i);
  }
  if (zeros != NULL) *zeros = count;
  return NANOARROW_OK;
}

/* The offsets [from, from + n] rebased to start at zero; `first` and
   `last` are the first and last offsets read. */
static int zar_copy_offsets(struct ArrowBuffer *dst, const struct ArrowBufferView *src,
                            int large, int64_t from, int64_t n, int64_t *first,
                            int64_t *last) {
  if (large) {
    const int64_t *off = src->data.as_int64 + from;
    *first = off[0];
    *last = off[n];
    NANOARROW_RETURN_NOT_OK(ArrowBufferReserve(dst, (n + 1) * 8));
    for (int64_t i = 0; i <= n; i++) {
      NANOARROW_RETURN_NOT_OK(ArrowBufferAppendInt64(dst, off[i] - *first));
    }
  } else {
    const int32_t *off = src->data.as_int32 + from;
    *first = off[0];
    *last = off[n];
    NANOARROW_RETURN_NOT_OK(ArrowBufferReserve(dst, (n + 1) * 4));
    for (int64_t i = 0; i <= n; i++) {
      NANOARROW_RETURN_NOT_OK(ArrowBufferAppendInt32(dst, (int32_t)(off[i] - *first)));
    }
  }
  return NANOARROW_OK;
}

static int zar_copy_node(const struct ArrowArrayView *v, struct ArrowArray *out,
                         int64_t start, int64_t n, const char **kind,
                         struct ArrowError *error);

/* Rows [from, from + n) of a validated run-end encoded view: the runs that
   cover them, their ends rebased to the first row and the last one cut at
   `n`, and the values of those runs. */
static int zar_copy_runs(const struct ArrowArrayView *v, struct ArrowArray *out,
                         int64_t from, int64_t n, const char **kind,
                         struct ArrowError *error) {
  const struct ArrowArrayView *ends = v->children[0];
  int64_t first = 0;
  int64_t count = 0;
  if (n > 0) {
    /* The first run whose end is past `from`, then the first whose end
       reaches `from + n`; run ends are strictly increasing. */
    int64_t lo = 0, hi = ends->length - 1;
    while (lo < hi) {
      int64_t mid = lo + (hi - lo) / 2;
      if (ArrowArrayViewGetIntUnsafe(ends, mid) > from) hi = mid; else lo = mid + 1;
    }
    first = lo;
    hi = ends->length - 1;
    while (lo < hi) {
      int64_t mid = lo + (hi - lo) / 2;
      if (ArrowArrayViewGetIntUnsafe(ends, mid) >= from + n) hi = mid; else lo = mid + 1;
    }
    count = lo - first + 1;
  }
  struct ArrowArray *out_ends = out->children[0];
  struct ArrowBuffer *buffer = ArrowArrayBuffer(out_ends, 1);
  for (int64_t i = 0; i < count; i++) {
    int64_t end = ArrowArrayViewGetIntUnsafe(ends, first + i) - from;
    if (end > n) end = n;
    switch (ends->storage_type) {
      case NANOARROW_TYPE_INT16:
        NANOARROW_RETURN_NOT_OK(ArrowBufferAppendInt16(buffer, (int16_t)end));
        break;
      case NANOARROW_TYPE_INT32:
        NANOARROW_RETURN_NOT_OK(ArrowBufferAppendInt32(buffer, (int32_t)end));
        break;
      default:
        NANOARROW_RETURN_NOT_OK(ArrowBufferAppendInt64(buffer, end));
        break;
    }
  }
  out_ends->offset = 0;
  out_ends->length = count;
  out_ends->null_count = 0;
  return zar_copy_node(v->children[1], out->children[1], first, count, kind, error);
}

/* Copies elements [start, start + n) of a validated view into `out`, an
   array initialised from the same schema, at offset zero. Sets `*kind`
   for a failure that is not an allocation's. */
static int zar_copy_node(const struct ArrowArrayView *v, struct ArrowArray *out,
                         int64_t start, int64_t n, const char **kind,
                         struct ArrowError *error) {
  int64_t from = v->offset + start;
  out->offset = 0;
  out->length = n;
  out->null_count = 0;

  if (v->layout.buffer_type[0] == NANOARROW_BUFFER_TYPE_VALIDITY &&
      v->buffer_views[0].data.data != NULL && v->null_count != 0) {
    struct ArrowBuffer *validity = ArrowArrayBuffer(out, 0);
    int64_t nulls = 0;
    NANOARROW_RETURN_NOT_OK(
        zar_copy_bits(validity, v->buffer_views[0].data.as_uint8, from, n, &nulls));
    if (nulls == 0) ArrowBufferReset(validity);
    out->null_count = nulls;
  }

  int64_t first, last;
  switch (v->storage_type) {
    case NANOARROW_TYPE_NA:
      out->null_count = n;
      break;
    case NANOARROW_TYPE_STRING:
    case NANOARROW_TYPE_BINARY:
    case NANOARROW_TYPE_LARGE_STRING:
    case NANOARROW_TYPE_LARGE_BINARY: {
      int large = v->storage_type == NANOARROW_TYPE_LARGE_STRING ||
                  v->storage_type == NANOARROW_TYPE_LARGE_BINARY;
      NANOARROW_RETURN_NOT_OK(zar_copy_offsets(ArrowArrayBuffer(out, 1),
                                               &v->buffer_views[1], large, from, n,
                                               &first, &last));
      if (last > first) {
        NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(out, 2),
                                                  v->buffer_views[2].data.as_uint8 + first,
                                                  last - first));
      }
      break;
    }
    case NANOARROW_TYPE_LIST:
    case NANOARROW_TYPE_MAP:
    case NANOARROW_TYPE_LARGE_LIST:
      NANOARROW_RETURN_NOT_OK(zar_copy_offsets(
          ArrowArrayBuffer(out, 1), &v->buffer_views[1],
          v->storage_type == NANOARROW_TYPE_LARGE_LIST, from, n, &first, &last));
      NANOARROW_RETURN_NOT_OK(zar_copy_node(v->children[0], out->children[0], first,
                                            last - first, kind, error));
      break;
    case NANOARROW_TYPE_FIXED_SIZE_LIST: {
      int64_t size = v->layout.child_size_elements;
      NANOARROW_RETURN_NOT_OK(zar_copy_node(v->children[0], out->children[0],
                                            from * size, n * size, kind, error));
      break;
    }
    case NANOARROW_TYPE_STRUCT:
      for (int64_t i = 0; i < v->n_children; i++) {
        NANOARROW_RETURN_NOT_OK(
            zar_copy_node(v->children[i], out->children[i], from, n, kind, error));
      }
      break;
    case NANOARROW_TYPE_SPARSE_UNION:
    case NANOARROW_TYPE_DENSE_UNION: {
      int dense = v->storage_type == NANOARROW_TYPE_DENSE_UNION;
      NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(ArrowArrayBuffer(out, 0),
                                                v->buffer_views[0].data.as_int8 + from, n));
      if (dense) {
        /* The offsets point into whole children, which are copied whole. */
        NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(
            ArrowArrayBuffer(out, 1), v->buffer_views[1].data.as_int32 + from, n * 4));
      }
      for (int64_t i = 0; i < v->n_children; i++) {
        const struct ArrowArrayView *child = v->children[i];
        NANOARROW_RETURN_NOT_OK(zar_copy_node(child, out->children[i], dense ? 0 : from,
                                              dense ? child->length : n, kind, error));
      }
      break;
    }
    case NANOARROW_TYPE_RUN_END_ENCODED:
      NANOARROW_RETURN_NOT_OK(zar_copy_runs(v, out, from, n, kind, error));
      break;
    default: {
      /* One buffer of fixed-width values: booleans, numbers, temporal
         types, decimals, fixed-size binary and dictionary indices. */
      int64_t bits = v->layout.element_size_bits[1];
      if (v->layout.buffer_type[1] != NANOARROW_BUFFER_TYPE_DATA ||
          v->layout.buffer_type[2] != NANOARROW_BUFFER_TYPE_NONE ||
          !(bits == 1 || (bits > 0 && bits % 8 == 0))) {
        ArrowErrorSet(error, "a sliced array of type %s cannot be copied",
                      ArrowTypeString(v->storage_type));
        *kind = "type";
        return ENOTSUP;
      }
      if (bits == 1) {
        NANOARROW_RETURN_NOT_OK(zar_copy_bits(ArrowArrayBuffer(out, 1),
                                              v->buffer_views[1].data.as_uint8, from, n,
                                              NULL));
      } else if (n > 0) {
        int64_t width = bits / 8;
        NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(
            ArrowArrayBuffer(out, 1), v->buffer_views[1].data.as_uint8 + from * width,
            n * width));
      }
      break;
    }
  }

  /* A dictionary is copied whole: the indices point into all of it. */
  if (v->dictionary != NULL) {
    NANOARROW_RETURN_NOT_OK(zar_copy_node(v->dictionary, out->dictionary, 0,
                                          v->dictionary->length, kind, error));
  }
  return NANOARROW_OK;
}

/* An unsliced copy of a batch whose view has an offset somewhere, for the
   encoder, whose message has no place for one. */
static int zar_unslice(const struct ArrowArrayView *view, const struct ArrowSchema *schema,
                       struct ArrowArray *out, const char **kind,
                       struct ArrowError *error) {
  int code = ArrowArrayInitFromSchema(out, schema, error);
  if (code != NANOARROW_OK) {
    *kind = "format";
    return code;
  }
  code = zar_copy_node(view, out, 0, view->length, kind, error);
  if (code == NANOARROW_OK) {
    code = ArrowArrayFinishBuildingDefault(out, error);
    if (code != NANOARROW_OK) *kind = "format";
  }
  return code;
}

/* Rows [start, start + n) of an array handle as a new array at offset 0,
   with its schema in the tag. A registered column is built once by its
   `from` handler and each batch is cut from that array this way (section
   6.10), so one batch and many give the same values. The copy has no
   offset anywhere, so it can be written. A view layout, which cannot be
   written, is a type failure. */
SEXP zar_c_array_slice(SEXP x, SEXP r_start, SEXP r_n) {
  struct ArrowError error;
  error.message[0] = '\0';
  struct ArrowArray *array = zar_array_from_xptr(x, &error);
  if (array == NULL) return zar_failure_from_error("handle", &error);
  SEXP tag = zar_array_schema_xptr(x, &error);
  if (tag == NULL) return zar_failure_from_error("handle", &error);
  struct ArrowSchema *schema = zar_schema_from_xptr(tag, &error);
  if (schema == NULL) return zar_failure_from_error("handle", &error);

  double start = Rf_asReal(r_start);
  double n_real = Rf_asReal(r_n);
  if (!(start >= 0) || !(n_real >= 0) || start + n_real > (double)array->length) {
    return zar_failure("handle", "the slice is outside the array");
  }

  struct ArrowArrayView view;
  int code = ArrowArrayViewInitFromSchema(&view, schema, &error);
  if (code != NANOARROW_OK) {
    return zar_failure_from_error(zar_code_kind(code, "format"), &error);
  }
  /* The values are copied below: check every offset and range first. */
  code = ArrowArrayViewSetArray(&view, array, &error);
  if (code == NANOARROW_OK) code = zar_view_check_read(&view, &error);
  if (code != NANOARROW_OK) {
    ArrowArrayViewReset(&view);
    return zar_failure_from_error(zar_code_kind(code, "format"), &error);
  }

  SEXP out = PROTECT(zar_array_owning_xptr(tag));
  struct ArrowArray *dst = (struct ArrowArray *)R_ExternalPtrAddr(out);
  const char *kind = "format";
  code = ArrowArrayInitFromSchema(dst, schema, &error);
  if (code == NANOARROW_OK) {
    kind = NULL;
    code = zar_copy_node(&view, dst, (int64_t)start, (int64_t)n_real, &kind, &error);
    if (code != NANOARROW_OK && kind == NULL) {
      kind = "format";
      ArrowErrorSet(&error, "the slice could not be copied");
    }
  }
  if (code == NANOARROW_OK) {
    code = ArrowArrayFinishBuildingDefault(dst, &error);
    if (code != NANOARROW_OK) kind = "format";
  }
  ArrowArrayViewReset(&view);
  UNPROTECT(1);
  if (code != NANOARROW_OK) return zar_failure_from_error(zar_code_kind(code, kind), &error);
  return out;
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

/* The order dictionary batches are written in, as ids of
   zar_collect_dicts(): a dictionary after every dictionary its values use,
   since a reader decodes a dictionary batch against those already read.
   `next_id` numbers the nodes as zar_collect_dicts() does. */
static void zar_order_dicts(const struct ArrowArrayView *view, int64_t *next_id,
                            int64_t *order, int64_t *n) {
  int64_t own = -1;
  if (view->dictionary != NULL) own = (*next_id)++;
  for (int64_t i = 0; i < view->n_children; i++) {
    zar_order_dicts(view->children[i], next_id, order, n);
  }
  if (view->dictionary != NULL) {
    zar_order_dicts(view->dictionary, next_id, order, n);
    order[(*n)++] = own;
  }
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
    return zar_failure("limit", "cannot allocate the writer");
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

  const char *kind = NULL;
  if (!zar_check_writable(schema, &error)) {
    SEXP fail = PROTECT(zar_write_fail("type", &error));
    UNPROTECT(2);
    return fail;
  }
  int code = ArrowIpcEncoderInit(&w->encoder);
  w->encoder_ready = code == NANOARROW_OK;
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
  int64_t *dict_order =
      (int64_t *)R_alloc((size_t)(w->n_dicts > 0 ? w->n_dicts : 1), sizeof(int64_t));
  /* The views of the last batch stay alive for the comparison: one view per
     batch, owned by R_alloc'ed storage and reset below. */
  struct ArrowArrayView *views = (struct ArrowArrayView *)R_alloc(
      (size_t)(Rf_xlength(arrays) > 0 ? Rf_xlength(arrays) : 1), sizeof(struct ArrowArrayView));
  R_xlen_t n_views = 0;
  w->copies = (struct ArrowArray *)calloc(
      (size_t)(Rf_xlength(arrays) > 0 ? Rf_xlength(arrays) : 1), sizeof(struct ArrowArray));
  if (w->copies == NULL || w->dict_views == NULL) {
    ArrowErrorSet(&error, "cannot allocate the writer");
    if (code == NANOARROW_OK) code = ENOMEM;
  }
  w->n_copies = w->copies == NULL ? 0 : Rf_xlength(arrays);

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
    /* The view is copied and encoded below: check every offset and range
       first (#150). */
    if (code == NANOARROW_OK) code = zar_view_check_read(view, &error);
    if (code != NANOARROW_OK) {
      kind = "format";
      break;
    }
    zar_fill_null_counts(view);
    if (view->null_count != 0 && ArrowArrayViewComputeNullCount(view) != 0) {
      ArrowErrorSet(&error,
                    "batch %ld has null rows, which an IPC record batch cannot hold",
                    (long)(b + 1));
      kind = "type";
      code = EINVAL;
      break;
    }
    /* A sliced batch is written as the values it holds (section 6.8). */
    if (zar_needs_copy(view)) {
      code = zar_unslice(view, schema, &w->copies[b], &kind, &error);
      if (code == NANOARROW_OK) code = ArrowArrayViewSetArray(view, &w->copies[b], &error);
      if (code != NANOARROW_OK) {
        if (kind == NULL) kind = "format";
        break;
      }
      zar_fill_null_counts(view);
    }

    /* Dictionaries: written before the first batch, and again only when a
       stream's batch brings a different one, each after those its values
       use. */
    int64_t n = 0;
    code = zar_collect_dicts(view, batch_dicts, w->n_dicts, &n);
    int64_t next_id = 0, n_order = 0;
    if (code == NANOARROW_OK) zar_order_dicts(view, &next_id, dict_order, &n_order);
    for (int64_t j = 0; code == NANOARROW_OK && j < n_order; j++) {
      int64_t k = dict_order[j];
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
    /* An allocation failure is a limit at whatever step it happens
       (section 6.8, #233), the codec's included; otherwise the codec
       callback names its own failures, and anything else the encoder
       refuses is malformed input. */
    if (code == ENOMEM) kind = "limit";
    if (kind == NULL) kind = w->kind;
    if (kind == NULL) kind = "format";
    SEXP fail = PROTECT(zar_write_fail(kind, &error));
    UNPROTECT(2);
    return fail;
  }
  SEXP out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)w->out.size_bytes));
  if (w->out.size_bytes > 0) memcpy(RAW(out), w->out.data, (size_t)w->out.size_bytes);
  UNPROTECT(2);
  return out;
}
