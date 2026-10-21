/*
 * Modified for the zuarrow R package: dictionary batches with compressed
 * bodies are decompressed (tools/patches/0003-dictionary-compression.patch),
 * the reader decodes the binary-view, string-view, list-view and
 * run-end-encoded layouts (tools/patches/0004-ipc-views-and-ree.patch), and
 * a bad file trailer is reported without reading past the input
 * (tools/patches/0005-footer-magic-read.patch), and a message length near
 * INT32_MAX is rejected before it overflows
 * (tools/patches/0006-header-size-overflow.patch), and a dictionary encoding
 * without an index type reads as int32, as the format says
 * (tools/patches/0007-dictionary-index-type.patch), and a message, footer or
 * field whose union names a table it does not carry is an error, not a NULL
 * read (tools/patches/0008-absent-tables.patch), and a dictionary batch's
 * field nodes and buffers are counted against its schema like a record
 * batch's (tools/patches/0009-dictionary-batch-counts.patch), metadata
 * keys and values are read by their stored length, absent ones as empty
 * (tools/patches/0010-metadata-strings.patch), and the encoder writes
 * dictionary batches and compressed bodies through a caller's buffer
 * callback, and the footer lists the dictionary blocks with every padding
 * byte zeroed (tools/patches/0013-encode-batches.patch).
 */
#include "nanoarrow_ipc_flatcc_generated.h"
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include <inttypes.h>

#include "nanoarrow_ipc.h"

#if defined(NANOARROW_IPC_WITH_ZSTD)
#include <zstd.h>

static ArrowErrorCode ArrowIpcDecompressZstd(struct ArrowBufferView src, uint8_t* dst,
                                             int64_t dst_size, struct ArrowError* error) {
  size_t code =
      ZSTD_decompress((void*)dst, (size_t)dst_size, src.data.data, src.size_bytes);
  if (ZSTD_isError(code)) {
    ArrowErrorSet(error,
                  "ZSTD_decompress([buffer with %" PRId64
                  " bytes] -> [buffer with %" PRId64 " bytes]) failed with error '%s'",
                  src.size_bytes, dst_size, ZSTD_getErrorName(code));
    return EIO;
  }

  if (dst_size != (int64_t)code) {
    ArrowErrorSet(error,
                  "Expected decompressed size of %" PRId64 " bytes but got %" PRId64
                  " bytes",
                  dst_size, (int64_t)code);
    return EIO;
  }

  return NANOARROW_OK;
}
#endif

ArrowIpcDecompressFunction ArrowIpcGetZstdDecompressionFunction(void) {
#if defined(NANOARROW_IPC_WITH_ZSTD)
  return &ArrowIpcDecompressZstd;
#else
  return NULL;
#endif
}

#if defined(NANOARROW_IPC_WITH_LZ4)
#include <lz4.h>
#include <lz4frame.h>

static ArrowErrorCode ArrowIpcDecompressLZ4(struct ArrowBufferView src, uint8_t* dst,
                                            int64_t dst_size, struct ArrowError* error) {
  LZ4F_errorCode_t ret;
  LZ4F_decompressionContext_t ctx = NULL;

  ret = LZ4F_createDecompressionContext(&ctx, LZ4F_VERSION);
  if (LZ4F_isError(ret)) {
    ArrowErrorSet(error, "LZ4 init failed");
    return EIO;
  }

  size_t dst_capacity = dst_size;
  size_t src_size = src.size_bytes;
  ret = LZ4F_decompress(ctx, dst, &dst_capacity, src.data.data, &src_size,
                        NULL /* options */);
  if (LZ4F_isError(ret)) {
    NANOARROW_UNUSED(LZ4F_freeDecompressionContext(ctx));
    ArrowErrorSet(error,
                  "LZ4F_decompress([buffer with %" PRId64
                  " bytes] -> [buffer with %" PRId64 " bytes]) failed",
                  src.size_bytes, dst_size);
    return EIO;
  }

  if ((int64_t)dst_capacity != dst_size) {
    NANOARROW_UNUSED(LZ4F_freeDecompressionContext(ctx));
    ArrowErrorSet(error,
                  "Expected decompressed size of %" PRId64 " bytes but got %" PRId64
                  " bytes",
                  dst_size, (int64_t)dst_capacity);
    return EIO;
  }

  if (ret != 0) {
    NANOARROW_UNUSED(LZ4F_freeDecompressionContext(ctx));
    ArrowErrorSet(error,
                  "Expected complete LZ4 frame but found frame with %" PRId64
                  " bytes remaining",
                  (int64_t)ret);
    return EIO;
  }

  NANOARROW_UNUSED(LZ4F_freeDecompressionContext(ctx));
  return NANOARROW_OK;
}
#endif

ArrowIpcDecompressFunction ArrowIpcGetLZ4DecompressionFunction(void) {
#if defined(NANOARROW_IPC_WITH_LZ4)
  return &ArrowIpcDecompressLZ4;
#else
  return NULL;
#endif
}

struct ArrowIpcSerialDecompressorPrivate {
  ArrowIpcDecompressFunction decompress_functions[3];
};

static ArrowErrorCode ArrowIpcSerialDecompressorAdd(
    struct ArrowIpcDecompressor* decompressor,
    enum ArrowIpcCompressionType compression_type, struct ArrowBufferView src,
    uint8_t* dst, int64_t dst_size, struct ArrowError* error) {
  struct ArrowIpcSerialDecompressorPrivate* private_data =
      (struct ArrowIpcSerialDecompressorPrivate*)decompressor->private_data;

  ArrowIpcDecompressFunction fn = NULL;
  switch (compression_type) {
    case NANOARROW_IPC_COMPRESSION_TYPE_ZSTD:
    case NANOARROW_IPC_COMPRESSION_TYPE_LZ4_FRAME:
      fn = private_data->decompress_functions[compression_type];
      break;
    default:
      ArrowErrorSet(error, "Unknown decompression type with value %d",
                    (int)compression_type);
      return EINVAL;
  }

  if (fn == NULL) {
    ArrowErrorSet(
        error, "Compression type with value %d not supported by this build of nanoarrow",
        (int)compression_type);
    return ENOTSUP;
  }

  NANOARROW_RETURN_NOT_OK(fn(src, dst, dst_size, error));
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcSerialDecompressorWait(
    struct ArrowIpcDecompressor* decompressor, int64_t timeout_ms,
    struct ArrowError* error) {
  NANOARROW_UNUSED(decompressor);
  NANOARROW_UNUSED(timeout_ms);
  NANOARROW_UNUSED(error);
  return NANOARROW_OK;
}

static void ArrowIpcSerialDecompressorRelease(struct ArrowIpcDecompressor* decompressor) {
  ArrowFree(decompressor->private_data);
  decompressor->release = NULL;
}

ArrowErrorCode ArrowIpcSerialDecompressor(struct ArrowIpcDecompressor* decompressor) {
  decompressor->decompress_add = &ArrowIpcSerialDecompressorAdd;
  decompressor->decompress_wait = &ArrowIpcSerialDecompressorWait;
  decompressor->release = &ArrowIpcSerialDecompressorRelease;
  decompressor->private_data =
      ArrowMalloc(sizeof(struct ArrowIpcSerialDecompressorPrivate));
  if (decompressor->private_data == NULL) {
    return ENOMEM;
  }

  memset(decompressor->private_data, 0, sizeof(struct ArrowIpcSerialDecompressorPrivate));
  ArrowIpcSerialDecompressorSetFunction(decompressor, NANOARROW_IPC_COMPRESSION_TYPE_ZSTD,
                                        ArrowIpcGetZstdDecompressionFunction());
  ArrowIpcSerialDecompressorSetFunction(decompressor,
                                        NANOARROW_IPC_COMPRESSION_TYPE_LZ4_FRAME,
                                        ArrowIpcGetLZ4DecompressionFunction());
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcSerialDecompressorSetFunction(
    struct ArrowIpcDecompressor* decompressor,
    enum ArrowIpcCompressionType compression_type,
    ArrowIpcDecompressFunction decompress_function) {
  struct ArrowIpcSerialDecompressorPrivate* private_data =
      (struct ArrowIpcSerialDecompressorPrivate*)decompressor->private_data;

  switch (compression_type) {
    case NANOARROW_IPC_COMPRESSION_TYPE_ZSTD:
    case NANOARROW_IPC_COMPRESSION_TYPE_LZ4_FRAME:
      break;
    default:
      return EINVAL;
  }

  private_data->decompress_functions[compression_type] = decompress_function;
  return NANOARROW_OK;
}
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "nanoarrow.h"
#include "nanoarrow_ipc.h"

// ENODATA is an XSI extension and is not defined by all libcs (e.g., older
// Windows/MinGW toolchains used by R 3.6, FreeBSD, and OpenBSD).
#if !defined(ENODATA)
#define ENODATA 120
#endif

#define NANOARROW_IPC_MAGIC "ARROW1"

#define NANOARROW_IPC_NO_DICTIONARY_ID INT64_MIN

#define ns(x) FLATBUFFERS_WRAP_NAMESPACE(org_apache_arrow_flatbuf, x)

// Internal representation of a parsed "Field" from flatbuffers. This
// represents a field in a depth-first walk of column arrays and their
// children.
struct ArrowIpcField {
  // Pointer to the ArrowIpcDecoderPrivate::array_view or child for this node
  struct ArrowArrayView* array_view;
  // Pointer to the ArrowIpcDecoderPrivate::array or child for this node. This
  // array is scratch space for any intermediary allocations (i.e., it is never moved
  // to the user).
  struct ArrowArray* array;
  // The cumulative number of buffers preceding this node.
  int64_t buffer_offset;
  // Dictionary identifier (or NANOARROW_IPC_NO_DICTIONARY_ID if this is not a
  // dictionary-encoded field)
  int64_t dictionary_id;
  // The number of binary-view and string-view nodes preceding this node, which
  // indexes RecordBatch.variadicBufferCounts.
  int64_t view_index;
};

// Internal data specific to the read/decode process
struct ArrowIpcDecoderPrivate {
  // The endianness that will be assumed for decoding future RecordBatch messages
  enum ArrowIpcEndianness endianness;
  // A cached system endianness value
  enum ArrowIpcEndianness system_endianness;
  // An ArrowArrayView whose length/null_count/buffers are set directly from the
  // deserialized flatbuffer message (i.e., no fully underlying ArrowArray exists,
  // although some buffers may be temporarily owned by ArrowIpcDecoderPrivate::array).
  struct ArrowArrayView array_view;
  // An ArrowArray with the same structure as the ArrowArrayView whose ArrowArrayBuffer()
  // values are used to allocate or store memory when this is required. This ArrowArray
  // is never moved to the caller; however, its buffers may be moved to the final output
  // ArrowArray if the caller requests one.
  struct ArrowArray array;
  // The number of fields in the flattened depth-first walk of columns and their children
  int64_t n_fields;
  // Array of cached information such that given a field index it is possible to locate
  // the ArrowArrayView/ArrowArray where the depth-first buffer/field walk should start.
  struct ArrowIpcField* fields;
  // The number of buffers that future RecordBatch messages must have to match the schema
  // that has been set.
  int64_t n_buffers;
  // The number of union fields in the Schema.
  int64_t n_union_fields;
  // A pointer to the last flatbuffers message.
  const void* last_message;
  // Storage for a DictionaryBatch
  struct ArrowIpcDictionaryBatch dictionary;
  // Storage for a Footer
  struct ArrowIpcFooter footer;
  // Decompressor for compression support
  struct ArrowIpcDecompressor decompressor;
  // The number of binary-view and string-view nodes in the schema
  int64_t n_view_fields;
};

ArrowErrorCode ArrowIpcCheckRuntime(struct ArrowError* error) {
  // Avoids unused warnings when bundling the header into nanoarrow_ipc.c
  NANOARROW_UNUSED(flatbuffers_end);
  NANOARROW_UNUSED(flatcc_builder_is_nested);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Null_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Struct__required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_List_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_LargeList_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_ListView_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_LargeListView_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_FixedSizeList_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Map_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Union_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Int_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_FloatingPoint_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Utf8_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Binary_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_LargeUtf8_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_LargeBinary_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Utf8View_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_BinaryView_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_FixedSizeBinary_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Bool_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_RunEndEncoded_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Decimal_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Date_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Time_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Timestamp_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Interval_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Duration_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_KeyValue_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_DictionaryEncoding_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Field_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Schema_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Footer_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_TensorDim_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Tensor_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_SparseTensorIndexCOO_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_SparseMatrixIndexCSX_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_SparseTensorIndexCSF_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_SparseTensor_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_BodyCompression_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_RecordBatch_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_DictionaryBatch_required);
  NANOARROW_UNUSED(__org_apache_arrow_flatbuf_Message_required);

  const char* nanoarrow_runtime_version = ArrowNanoarrowVersion();
  const char* nanoarrow_ipc_build_time_version = NANOARROW_VERSION;

  if (strcmp(nanoarrow_runtime_version, nanoarrow_ipc_build_time_version) != 0) {
    ArrowErrorSet(error, "Expected nanoarrow runtime version '%s' but found version '%s'",
                  nanoarrow_ipc_build_time_version, nanoarrow_runtime_version);
    return EINVAL;
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderNeedsSwapEndian(struct ArrowIpcDecoder* decoder) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;
  switch (private_data->endianness) {
    case NANOARROW_IPC_ENDIANNESS_LITTLE:
    case NANOARROW_IPC_ENDIANNESS_BIG:
      return private_data->endianness != NANOARROW_IPC_ENDIANNESS_UNINITIALIZED &&
             private_data->endianness != private_data->system_endianness;
    default:
      return 0;
  }
}

void ArrowIpcDictionaryEncodingsInit(
    struct ArrowIpcDictionaryEncodings* dictionary_encodings) {
  NANOARROW_DCHECK(dictionary_encodings != NULL);
  ArrowBufferInit(&dictionary_encodings->encodings);
}

ArrowErrorCode ArrowIpcDictionaryEncodingsAppend(
    struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    struct ArrowIpcDictionaryEncoding encoding) {
  NANOARROW_DCHECK(dictionary_encodings != NULL);
  NANOARROW_RETURN_NOT_OK(ArrowBufferAppend(&dictionary_encodings->encodings, &encoding,
                                            sizeof(struct ArrowIpcDictionaryEncoding)));
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcDictionaryEncodingsAppendSchemaInternal(
    struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    const struct ArrowSchema* schema, int64_t* next_id) {
  if (schema->dictionary != NULL) {
    struct ArrowIpcDictionaryEncoding encoding;
    encoding.schema = schema;
    encoding.id = (*next_id)++;
    encoding.kind = NANOARROW_IPC_DICTIONARY_KIND_DENSE_ARRAY;
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcDictionaryEncodingsAppend(dictionary_encodings, encoding));
  }

  for (int64_t i = 0; i < schema->n_children; i++) {
    NANOARROW_DCHECK(schema->children != NULL && schema->children[i] != NULL);
    NANOARROW_RETURN_NOT_OK(ArrowIpcDictionaryEncodingsAppendSchemaInternal(
        dictionary_encodings, schema->children[i], next_id));
  }

  if (schema->dictionary != NULL) {
    NANOARROW_RETURN_NOT_OK(ArrowIpcDictionaryEncodingsAppendSchemaInternal(
        dictionary_encodings, schema->dictionary, next_id));
  }

  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDictionaryEncodingsAppendSchema(
    struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    const struct ArrowSchema* schema) {
  NANOARROW_DCHECK(dictionary_encodings != NULL);

  int64_t next_id = 0;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDictionaryEncodingsAppendSchemaInternal(
      dictionary_encodings, schema, &next_id));

  return NANOARROW_OK;
}

const struct ArrowIpcDictionaryEncoding* ArrowIpcDictionaryEncodingsFind(
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    const struct ArrowSchema* schema) {
  NANOARROW_DCHECK(dictionary_encodings != NULL);
  int64_t length = dictionary_encodings->encodings.size_bytes /
                   sizeof(struct ArrowIpcDictionaryEncoding);
  const struct ArrowIpcDictionaryEncoding* data =
      (const struct ArrowIpcDictionaryEncoding*)dictionary_encodings->encodings.data;

  for (int64_t i = 0; i < length; i++) {
    const struct ArrowIpcDictionaryEncoding* encoding = data + i;
    if (encoding->schema == schema) {
      return encoding;
    }
  }

  return NULL;
}

const struct ArrowIpcDictionaryEncoding* ArrowIpcDictionaryEncodingsFindById(
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings, int64_t id) {
  NANOARROW_DCHECK(dictionary_encodings != NULL);
  int64_t length = dictionary_encodings->encodings.size_bytes /
                   sizeof(struct ArrowIpcDictionaryEncoding);
  const struct ArrowIpcDictionaryEncoding* data =
      (const struct ArrowIpcDictionaryEncoding*)dictionary_encodings->encodings.data;

  for (int64_t i = 0; i < length; i++) {
    const struct ArrowIpcDictionaryEncoding* encoding = data + i;
    if (encoding->id == id) {
      return encoding;
    }
  }

  return NULL;
}

static int ArrowIpcIdsListContains(const struct ArrowBuffer* ids_buffer, int64_t num_ids,
                                   int64_t id) {
  const int64_t* ids = (const int64_t*)ids_buffer->data;
  for (int64_t i = 0; i < num_ids; i++) {
    if (ids[i] == id) {
      return 1;
    }
  }

  return 0;
}

ArrowErrorCode ArrowIpcDictionaryEncodingsUniqueIds(
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    struct ArrowBuffer* out) {
  NANOARROW_DCHECK(dictionary_encodings != NULL);
  int64_t length = dictionary_encodings->encodings.size_bytes /
                   sizeof(struct ArrowIpcDictionaryEncoding);
  const struct ArrowIpcDictionaryEncoding* data =
      (const struct ArrowIpcDictionaryEncoding*)dictionary_encodings->encodings.data;

  struct ArrowBuffer tmp;
  ArrowBufferInit(&tmp);

  ArrowErrorCode result;
  int64_t num_ids = 0;
  for (int64_t i = 0; i < length; i++) {
    const struct ArrowIpcDictionaryEncoding* encoding = data + i;
    if (!ArrowIpcIdsListContains(&tmp, num_ids, encoding->id)) {
      result = ArrowBufferAppendInt64(&tmp, encoding->id);
      if (result != NANOARROW_OK) {
        ArrowBufferReset(&tmp);
        return result;
      }

      ++num_ids;
    }
  }

  ArrowBufferMove(&tmp, out);
  return NANOARROW_OK;
}

void ArrowIpcDictionaryEncodingsReset(
    struct ArrowIpcDictionaryEncodings* dictionary_encodings) {
  NANOARROW_DCHECK(dictionary_encodings != NULL);
  ArrowBufferReset(&dictionary_encodings->encodings);
}

/// \brief Internal member of an ArrowIpcDictionaries
///
/// This structure stores a dictionary-specific decoder and the current value
/// of the dictionary (if one exists).
struct ArrowIpcDictionary {
  int64_t id;
  struct ArrowIpcDecoder decoder;
  struct ArrowArray current_value;
};

static ArrowErrorCode ArrowIpcDictionaryInit(struct ArrowIpcDictionary* dictionary) {
  dictionary->id = NANOARROW_IPC_NO_DICTIONARY_ID;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderInit(&dictionary->decoder));
  memset(&dictionary->current_value, 0, sizeof(struct ArrowArray));
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcDictionaryReplace(struct ArrowIpcDictionary* dictionary,
                                                struct ArrowArray* value,
                                                struct ArrowError* error) {
  NANOARROW_UNUSED(error);

  if (dictionary->current_value.release != NULL) {
    ArrowArrayRelease(&dictionary->current_value);
  }

  // Convert to a shared array so that clones can reference the same data
  // without copying
  struct ArrowArray shared;
  NANOARROW_RETURN_NOT_OK(ArrowArrayMoveShared(value, &shared));
  ArrowArrayMove(&shared, &dictionary->current_value);
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcDictionaryAppend(struct ArrowIpcDictionary* dictionary,
                                               struct ArrowArray* value,
                                               struct ArrowError* error) {
  if (dictionary->current_value.release != NULL &&
      dictionary->current_value.length != 0) {
    ArrowErrorSet(error, "Dictionary concatenation is not yet supported");
    return ENOTSUP;
  }

  NANOARROW_RETURN_NOT_OK(ArrowIpcDictionaryReplace(dictionary, value, error));
  return NANOARROW_OK;
}

static void ArrowIpcDictionaryReset(struct ArrowIpcDictionary* dictionary) {
  ArrowIpcDecoderReset(&dictionary->decoder);
  if (dictionary->current_value.release) {
    ArrowArrayRelease(&dictionary->current_value);
  }
}

struct ArrowIpcDictionariesPrivate {
  struct ArrowIpcDictionary* dictionaries;
  int64_t num_dictionaries;
};

static void ArrowIpcDictionariesNoOpSchemaRelease(struct ArrowSchema* schema) {
  NANOARROW_UNUSED(schema);
}

static ArrowErrorCode ArrowIpcDictionariesInitDictionaries(
    struct ArrowIpcDictionariesPrivate* private_data,
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    const struct ArrowBuffer* unique_ids_buffer, int64_t* num_initialized_decoders_out,
    struct ArrowError* error) {
  ArrowErrorCode result;
  const int64_t* unique_ids = (const int64_t*)unique_ids_buffer->data;

  // To set the schema of each ArrowIpcDictionary's encoder, we need to construct a
  // const ArrowSchema* that points to a struct with exactly one child that is the
  // value type. To support nested dictionaries that may exist within
  // ArrowIpcDictionaryEncodings, we can't deep copy the value type because it would
  // invalidate pointer references within dictionary_encodings (i.e., nested dictionaries
  // would fail to resolve when we call ArrowIpcDecoderSetSchemaWithDictionaries()).
  // To make this work, we create an ArrowSchema with a noop release to pass to
  // ArrowIpcDecoderSetSchemaWithDictionaries(). This works because that function
  // accepts a const value (i.e., never releases the schema argument).
  struct ArrowSchema decoder_schema;
  memset(&decoder_schema, 0, sizeof(struct ArrowSchema));
  decoder_schema.name = "";
  decoder_schema.format = "+s";
  decoder_schema.n_children = 1;
  decoder_schema.release = &ArrowIpcDictionariesNoOpSchemaRelease;

  for (int64_t i = 0; i < private_data->num_dictionaries; i++) {
    struct ArrowIpcDictionary* dictionary = private_data->dictionaries + i;
    result = ArrowIpcDictionaryInit(dictionary);
    if (result != NANOARROW_OK) {
      ArrowErrorSet(error, "Internal error (failed to initialize dictionary)");
      *num_initialized_decoders_out = i;
      return result;
    }

    const struct ArrowIpcDictionaryEncoding* encoding =
        ArrowIpcDictionaryEncodingsFindById(dictionary_encodings, unique_ids[i]);
    if (encoding == NULL) {
      ArrowErrorSet(error,
                    "Internal error (dictionary with id not present in encodings list)");
      *num_initialized_decoders_out = i + 1;
      return EINVAL;
    }

    // The decoder's schema will be a struct with one column (the value type of
    // the dictionary-encoded field)
    decoder_schema.children = (struct ArrowSchema**)&encoding->schema->dictionary;

    result = ArrowIpcDecoderSetSchemaWithDictionaries(
        &dictionary->decoder, &decoder_schema, dictionary_encodings, error);
    if (result != NANOARROW_OK) {
      *num_initialized_decoders_out = i + 1;
      return result;
    }

    // Set the ID
    dictionary->id = unique_ids[i];

    // Set the initial array value to a valid array with zero length. This is
    // needed because empty and/or all null columns may not have a dictionary
    // message emitted before a record batch arrives.
    struct ArrowArray initial_value;
    result =
        ArrowArrayInitFromSchema(&initial_value, encoding->schema->dictionary, error);
    if (result != NANOARROW_OK) {
      *num_initialized_decoders_out = i + 1;
      return result;
    }

    result = ArrowArrayFinishBuildingDefault(&initial_value, error);
    if (result != NANOARROW_OK) {
      ArrowArrayRelease(&initial_value);
      *num_initialized_decoders_out = i + 1;
      return result;
    }

    // Convert to a shared array so that clones can reference the same data
    // without copying
    result = ArrowArrayMoveShared(&initial_value, &dictionary->current_value);
    if (result != NANOARROW_OK) {
      ArrowArrayRelease(&initial_value);
      *num_initialized_decoders_out = i + 1;
      return result;
    }
  }

  *num_initialized_decoders_out = private_data->num_dictionaries;
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDictionariesInit(
    struct ArrowIpcDictionaries* dictionaries,
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    struct ArrowError* error) {
  NANOARROW_DCHECK(dictionaries != NULL);
  NANOARROW_DCHECK(dictionary_encodings != NULL);

  memset(dictionaries, 0, sizeof(struct ArrowIpcDictionaries));
  struct ArrowIpcDictionariesPrivate* private_data =
      (struct ArrowIpcDictionariesPrivate*)ArrowMalloc(
          sizeof(struct ArrowIpcDictionariesPrivate));
  if (private_data == NULL) {
    ArrowErrorSet(error, "Failed to allocate ArrowIpcDictionariesPrivate");
    return ENOMEM;
  }

  // Count the number of unique IDs. This will usually be the number of dictionary
  // encodings but may be much smaller if there are a lot of dictionary encoded fields
  // that use the same dictionary.
  struct ArrowBuffer unique_ids;
  ArrowErrorCode result =
      ArrowIpcDictionaryEncodingsUniqueIds(dictionary_encodings, &unique_ids);
  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "Failed to extract unique identifiers");
    ArrowFree(private_data);
    return result;
  }

  // unique_ids is a buffer of int64_t
  private_data->num_dictionaries = unique_ids.size_bytes / sizeof(int64_t);

  // Allocate the array of ArrowIpcDictionary
  if (private_data->num_dictionaries > 0) {
    private_data->dictionaries =
        ArrowMalloc(private_data->num_dictionaries * sizeof(struct ArrowIpcDictionary));
    if (private_data->dictionaries == NULL) {
      ArrowErrorSet(error, "Failed to allocate ArrowIpcDictionary array");
      ArrowBufferReset(&unique_ids);
      ArrowFree(private_data);
      return ENOMEM;
    }
  } else {
    private_data->dictionaries = NULL;
  }

  int64_t num_initialized_dictionaries = 0;
  result = ArrowIpcDictionariesInitDictionaries(private_data, dictionary_encodings,
                                                &unique_ids,
                                                &num_initialized_dictionaries, error);
  ArrowBufferReset(&unique_ids);
  if (result != NANOARROW_OK) {
    for (int64_t i = 0; i < num_initialized_dictionaries; i++) {
      ArrowIpcDictionaryReset(private_data->dictionaries + i);
    }

    ArrowFree(private_data->dictionaries);
    ArrowFree(private_data);
    return result;
  }

  dictionaries->private_data = private_data;
  return NANOARROW_OK;
}

static struct ArrowIpcDictionary* ArrowIpcDictionariesFindById(
    struct ArrowIpcDictionaries* dictionaries, int64_t id) {
  NANOARROW_DCHECK(dictionaries != NULL);

  struct ArrowIpcDictionariesPrivate* private_data =
      (struct ArrowIpcDictionariesPrivate*)dictionaries->private_data;
  for (int64_t i = 0; i < private_data->num_dictionaries; i++) {
    struct ArrowIpcDictionary* dictionary = private_data->dictionaries + i;
    if (dictionary->id == id) {
      return dictionary;
    }
  }

  return NULL;
}

ArrowErrorCode ArrowIpcDictionariesFindCurrentValue(
    struct ArrowIpcDictionaries* dictionaries, int64_t id, const struct ArrowArray** out,
    struct ArrowError* error) {
  struct ArrowIpcDictionary* dictionary = ArrowIpcDictionariesFindById(dictionaries, id);
  if (dictionary == NULL) {
    ArrowErrorSet(error,
                  "Can't find value for dictionary with ID %" PRId64
                  " (dictionary definition not found)",
                  id);
    return EINVAL;
  }

  *out = &dictionary->current_value;
  return NANOARROW_OK;
}

void ArrowIpcDictionariesReset(struct ArrowIpcDictionaries* dictionaries) {
  NANOARROW_DCHECK(dictionaries != NULL);
  struct ArrowIpcDictionariesPrivate* private_data =
      (struct ArrowIpcDictionariesPrivate*)dictionaries->private_data;

  for (int64_t i = 0; i < private_data->num_dictionaries; i++) {
    struct ArrowIpcDictionary* dictionary = private_data->dictionaries + i;
    ArrowIpcDictionaryReset(dictionary);
  }

  ArrowFree(private_data->dictionaries);
  ArrowFree(private_data);
  dictionaries->private_data = NULL;
}

ArrowErrorCode ArrowIpcDecoderInit(struct ArrowIpcDecoder* decoder) {
  memset(decoder, 0, sizeof(struct ArrowIpcDecoder));
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)ArrowMalloc(sizeof(struct ArrowIpcDecoderPrivate));
  if (private_data == NULL) {
    return ENOMEM;
  }

  memset(private_data, 0, sizeof(struct ArrowIpcDecoderPrivate));
  private_data->system_endianness = ArrowIpcSystemEndianness();
  ArrowIpcFooterInit(&private_data->footer);
  decoder->private_data = private_data;
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcDecoderInitDecompressor(
    struct ArrowIpcDecoderPrivate* private_data) {
  if (private_data->decompressor.release == NULL) {
    NANOARROW_RETURN_NOT_OK(ArrowIpcSerialDecompressor(&private_data->decompressor));
  }

  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderSetDecompressor(struct ArrowIpcDecoder* decoder,
                                              struct ArrowIpcDecompressor* decompressor) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  if (private_data->decompressor.release != NULL) {
    private_data->decompressor.release(&private_data->decompressor);
  }

  memcpy(&private_data->decompressor, decompressor, sizeof(struct ArrowIpcDecompressor));
  decompressor->release = NULL;
  return NANOARROW_OK;
}

void ArrowIpcDecoderReset(struct ArrowIpcDecoder* decoder) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  if (private_data != NULL) {
    ArrowArrayViewReset(&private_data->array_view);

    if (private_data->array.release != NULL) {
      ArrowArrayRelease(&private_data->array);
    }

    if (private_data->fields != NULL) {
      ArrowFree(private_data->fields);
      private_data->n_fields = 0;
    }

    private_data->n_union_fields = 0;

    ArrowIpcFooterReset(&private_data->footer);

    if (private_data->decompressor.release != NULL) {
      private_data->decompressor.release(&private_data->decompressor);
    }

    ArrowFree(private_data);
    memset(decoder, 0, sizeof(struct ArrowIpcDecoder));
  }
}

static inline int32_t ArrowIpcReadInt32LE(struct ArrowBufferView* data, int swap_endian) {
  int32_t value;
  memcpy(&value, data->data.as_uint8, sizeof(int32_t));
  if (swap_endian) {
    value = bswap32(value);
  }

  data->data.as_uint8 += sizeof(int32_t);
  data->size_bytes -= sizeof(int32_t);
  return value;
}

static int ArrowIpcDecoderSetMetadata(struct ArrowSchema* schema,
                                      ns(KeyValue_vec_t) kv_vec,
                                      struct ArrowError* error) {
  int64_t n_pairs = ns(KeyValue_vec_len(kv_vec));
  if (n_pairs == 0) {
    return NANOARROW_OK;
  }

  if (n_pairs > 2147483647) {
    ArrowErrorSet(error,
                  "Expected between 0 and 2147483647 key/value pairs but found %" PRId64,
                  n_pairs);
    return EINVAL;
  }

  struct ArrowBuffer buf;
  struct ArrowStringView key;
  struct ArrowStringView value;
  ns(KeyValue_table_t) kv;

  int result = ArrowMetadataBuilderInit(&buf, NULL);
  if (result != NANOARROW_OK) {
    ArrowBufferReset(&buf);
    ArrowErrorSet(error, "ArrowMetadataBuilderInit() failed");
    return result;
  }

  for (int64_t i = 0; i < n_pairs; i++) {
    kv = ns(KeyValue_vec_at(kv_vec, i));

    // Both strings are optional, and a value may hold NUL bytes: read each by
    // its stored length, an absent one as empty.
    flatbuffers_string_t kv_key = kv == NULL ? NULL : ns(KeyValue_key(kv));
    flatbuffers_string_t kv_value = kv == NULL ? NULL : ns(KeyValue_value(kv));
    key.data = kv_key == NULL ? "" : kv_key;
    key.size_bytes = kv_key == NULL ? 0 : (int64_t)flatbuffers_string_len(kv_key);
    value.data = kv_value == NULL ? "" : kv_value;
    value.size_bytes = kv_value == NULL ? 0 : (int64_t)flatbuffers_string_len(kv_value);

    result = ArrowMetadataBuilderAppend(&buf, key, value);
    if (result != NANOARROW_OK) {
      ArrowBufferReset(&buf);
      ArrowErrorSet(error, "ArrowMetadataBuilderAppend() failed");
      return result;
    }
  }

  result = ArrowSchemaSetMetadata(schema, (const char*)buf.data);
  ArrowBufferReset(&buf);
  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "ArrowSchemaSetMetadata() failed");
    return result;
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetTypeSimple(struct ArrowSchema* schema, int nanoarrow_type,
                                        struct ArrowError* error) {
  int result = ArrowSchemaSetType(schema, nanoarrow_type);
  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "ArrowSchemaSetType() failed for type %s",
                  ArrowTypeString(nanoarrow_type));
    return result;
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetTypeInt(struct ArrowSchema* schema,
                                     flatbuffers_generic_t type_generic,
                                     struct ArrowError* error) {
  ns(Int_table_t) type = (ns(Int_table_t))type_generic;

  int is_signed = ns(Int_is_signed_get(type));
  int bitwidth = ns(Int_bitWidth_get(type));
  int nanoarrow_type = NANOARROW_TYPE_UNINITIALIZED;

  if (is_signed) {
    switch (bitwidth) {
      case 8:
        nanoarrow_type = NANOARROW_TYPE_INT8;
        break;
      case 16:
        nanoarrow_type = NANOARROW_TYPE_INT16;
        break;
      case 32:
        nanoarrow_type = NANOARROW_TYPE_INT32;
        break;
      case 64:
        nanoarrow_type = NANOARROW_TYPE_INT64;
        break;
      default:
        ArrowErrorSet(error,
                      "Expected signed int bitwidth of 8, 16, 32, or 64 but got %d",
                      bitwidth);
        return EINVAL;
    }
  } else {
    switch (bitwidth) {
      case 8:
        nanoarrow_type = NANOARROW_TYPE_UINT8;
        break;
      case 16:
        nanoarrow_type = NANOARROW_TYPE_UINT16;
        break;
      case 32:
        nanoarrow_type = NANOARROW_TYPE_UINT32;
        break;
      case 64:
        nanoarrow_type = NANOARROW_TYPE_UINT64;
        break;
      default:
        ArrowErrorSet(error,
                      "Expected unsigned int bitwidth of 8, 16, 32, or 64 but got %d",
                      bitwidth);
        return EINVAL;
    }
  }

  return ArrowIpcDecoderSetTypeSimple(schema, nanoarrow_type, error);
}

static int ArrowIpcDecoderSetTypeFloatingPoint(struct ArrowSchema* schema,
                                               flatbuffers_generic_t type_generic,
                                               struct ArrowError* error) {
  ns(FloatingPoint_table_t) type = (ns(FloatingPoint_table_t))type_generic;
  int precision = ns(FloatingPoint_precision(type));
  switch (precision) {
    case ns(Precision_HALF):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_HALF_FLOAT, error);
    case ns(Precision_SINGLE):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_FLOAT, error);
    case ns(Precision_DOUBLE):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_DOUBLE, error);
    default:
      ArrowErrorSet(error, "Unexpected FloatingPoint Precision value: %d", precision);
      return EINVAL;
  }
}

static int ArrowIpcDecoderSetTypeDecimal(struct ArrowSchema* schema,
                                         flatbuffers_generic_t type_generic,
                                         struct ArrowError* error) {
  ns(Decimal_table_t) type = (ns(Decimal_table_t))type_generic;
  int scale = ns(Decimal_scale(type));
  int precision = ns(Decimal_precision(type));
  int bitwidth = ns(Decimal_bitWidth(type));

  int result;
  switch (bitwidth) {
    case 32:
      result =
          ArrowSchemaSetTypeDecimal(schema, NANOARROW_TYPE_DECIMAL32, precision, scale);
      break;
    case 64:
      result =
          ArrowSchemaSetTypeDecimal(schema, NANOARROW_TYPE_DECIMAL64, precision, scale);
      break;
    case 128:
      result =
          ArrowSchemaSetTypeDecimal(schema, NANOARROW_TYPE_DECIMAL128, precision, scale);
      break;
    case 256:
      result =
          ArrowSchemaSetTypeDecimal(schema, NANOARROW_TYPE_DECIMAL256, precision, scale);
      break;
    default:
      ArrowErrorSet(error, "Unexpected Decimal bitwidth value: %d", bitwidth);
      return EINVAL;
  }

  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "ArrowSchemaSetTypeDecimal() failed");
    return result;
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetTypeFixedSizeBinary(struct ArrowSchema* schema,
                                                 flatbuffers_generic_t type_generic,
                                                 struct ArrowError* error) {
  ns(FixedSizeBinary_table_t) type = (ns(FixedSizeBinary_table_t))type_generic;
  int fixed_size = ns(FixedSizeBinary_byteWidth(type));
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowSchemaSetTypeFixedSize(schema, NANOARROW_TYPE_FIXED_SIZE_BINARY, fixed_size),
      error);
  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetTypeDate(struct ArrowSchema* schema,
                                      flatbuffers_generic_t type_generic,
                                      struct ArrowError* error) {
  ns(Date_table_t) type = (ns(Date_table_t))type_generic;
  int date_unit = ns(Date_unit(type));
  switch (date_unit) {
    case ns(DateUnit_DAY):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_DATE32, error);
    case ns(DateUnit_MILLISECOND):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_DATE64, error);
    default:
      ArrowErrorSet(error, "Unexpected Date DateUnit value: %d", (int)date_unit);
      return EINVAL;
  }
}

static int ArrowIpcDecoderSetTypeTime(struct ArrowSchema* schema,
                                      flatbuffers_generic_t type_generic,
                                      struct ArrowError* error) {
  ns(Time_table_t) type = (ns(Time_table_t))type_generic;
  int time_unit = ns(Time_unit(type));
  int bitwidth = ns(Time_bitWidth(type));
  int nanoarrow_type;

  switch (time_unit) {
    case ns(TimeUnit_SECOND):
    case ns(TimeUnit_MILLISECOND):
      if (bitwidth != 32) {
        ArrowErrorSet(error, "Expected bitwidth of 32 for Time TimeUnit %s but found %d",
                      ns(TimeUnit_name(ns(Time_unit(type)))), bitwidth);
        return EINVAL;
      }

      nanoarrow_type = NANOARROW_TYPE_TIME32;
      break;

    case ns(TimeUnit_MICROSECOND):
    case ns(TimeUnit_NANOSECOND):
      if (bitwidth != 64) {
        ArrowErrorSet(error, "Expected bitwidth of 64 for Time TimeUnit %s but found %d",
                      ns(TimeUnit_name(ns(Time_unit(type)))), bitwidth);
        return EINVAL;
      }

      nanoarrow_type = NANOARROW_TYPE_TIME64;
      break;

    default:
      ArrowErrorSet(error, "Unexpected Time TimeUnit value: %d", time_unit);
      return EINVAL;
  }

  int result = ArrowSchemaSetTypeDateTime(schema, nanoarrow_type, time_unit, NULL);
  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "ArrowSchemaSetTypeDateTime() failed");
    return result;
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetTypeTimestamp(struct ArrowSchema* schema,
                                           flatbuffers_generic_t type_generic,
                                           struct ArrowError* error) {
  ns(Timestamp_table_t) type = (ns(Timestamp_table_t))type_generic;
  int time_unit = ns(Timestamp_unit(type));

  const char* timezone = "";
  if (ns(Timestamp_timezone_is_present(type))) {
    timezone = ns(Timestamp_timezone_get(type));
  }

  int result =
      ArrowSchemaSetTypeDateTime(schema, NANOARROW_TYPE_TIMESTAMP, time_unit, timezone);
  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "ArrowSchemaSetTypeDateTime() failed");
    return result;
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetTypeDuration(struct ArrowSchema* schema,
                                          flatbuffers_generic_t type_generic,
                                          struct ArrowError* error) {
  ns(Duration_table_t) type = (ns(Duration_table_t))type_generic;
  int time_unit = ns(Duration_unit(type));

  int result =
      ArrowSchemaSetTypeDateTime(schema, NANOARROW_TYPE_DURATION, time_unit, NULL);
  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "ArrowSchemaSetTypeDateTime() failed");
    return result;
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetTypeInterval(struct ArrowSchema* schema,
                                          flatbuffers_generic_t type_generic,
                                          struct ArrowError* error) {
  ns(Interval_table_t) type = (ns(Interval_table_t))type_generic;
  int interval_unit = ns(Interval_unit(type));

  switch (interval_unit) {
    case ns(IntervalUnit_YEAR_MONTH):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_INTERVAL_MONTHS, error);
    case ns(IntervalUnit_DAY_TIME):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_INTERVAL_DAY_TIME,
                                          error);
    case ns(IntervalUnit_MONTH_DAY_NANO):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_INTERVAL_MONTH_DAY_NANO,
                                          error);
    default:
      ArrowErrorSet(error, "Unexpected Interval unit value: %d", interval_unit);
      return EINVAL;
  }
}

// We can't quite use nanoarrow's built-in SchemaSet functions for nested types
// because the IPC format allows modifying some of the defaults those functions assume.
// In particular, the allocate + initialize children step is handled outside these
// setters.
static int ArrowIpcDecoderSetTypeSimpleNested(struct ArrowSchema* schema,
                                              const char* format,
                                              struct ArrowError* error) {
  int result = ArrowSchemaSetFormat(schema, format);
  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "ArrowSchemaSetFormat('%s') failed", format);
    return result;
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetTypeFixedSizeList(struct ArrowSchema* schema,
                                               flatbuffers_generic_t type_generic,
                                               struct ArrowError* error) {
  ns(FixedSizeList_table_t) type = (ns(FixedSizeList_table_t))type_generic;
  int32_t fixed_size = ns(FixedSizeList_listSize(type));

  char fixed_size_str[128];
  int n_chars = snprintf(fixed_size_str, 128, "+w:%d", fixed_size);
  if (n_chars < 0) {
    ArrowErrorSet(error, "snprintf() encoding error");
    return ERANGE;
  }

  fixed_size_str[n_chars] = '\0';
  return ArrowIpcDecoderSetTypeSimpleNested(schema, fixed_size_str, error);
}

static int ArrowIpcDecoderSetTypeMap(struct ArrowSchema* schema,
                                     flatbuffers_generic_t type_generic,
                                     struct ArrowError* error) {
  ns(Map_table_t) type = (ns(Map_table_t))type_generic;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderSetTypeSimpleNested(schema, "+m", error));

  if (ns(Map_keysSorted(type))) {
    schema->flags |= ARROW_FLAG_MAP_KEYS_SORTED;
  } else {
    schema->flags &= ~ARROW_FLAG_MAP_KEYS_SORTED;
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetTypeUnion(struct ArrowSchema* schema,
                                       flatbuffers_generic_t type_generic,
                                       int64_t n_children, struct ArrowError* error) {
  ns(Union_table_t) type = (ns(Union_table_t))type_generic;
  int union_mode = ns(Union_mode(type));

  if (n_children < 0 || n_children > 127) {
    ArrowErrorSet(error,
                  "Expected between 0 and 127 children for Union type but found %" PRId64,
                  n_children);
    return EINVAL;
  }

  // Max valid typeIds size is 127; the longest single ID that could be present here
  // is -INT_MIN (11 chars). With commas and the prefix the max size would be
  // 1527 characters. (Any ids outside the range 0...127 are unlikely to be valid
  // elsewhere but they could in theory be present here).
  char union_types_str[2048];
  memset(union_types_str, 0, sizeof(union_types_str));
  char* format_cursor = union_types_str;
  int format_out_size = sizeof(union_types_str);
  int n_chars = 0;

  switch (union_mode) {
    case ns(UnionMode_Sparse):
      n_chars = snprintf(format_cursor, format_out_size, "+us:");
      format_cursor += n_chars;
      format_out_size -= n_chars;
      break;
    case ns(UnionMode_Dense):
      n_chars = snprintf(format_cursor, format_out_size, "+ud:");
      format_cursor += n_chars;
      format_out_size -= n_chars;
      break;
    default:
      ArrowErrorSet(error, "Unexpected Union UnionMode value: %d", union_mode);
      return EINVAL;
  }

  if (n_chars < 0) {
    ArrowErrorSet(error, "snprintf() encoding error");
    return ERANGE;
  }

  if (ns(Union_typeIds_is_present(type))) {
    flatbuffers_int32_vec_t type_ids = ns(Union_typeIds(type));
    int64_t n_type_ids = flatbuffers_int32_vec_len(type_ids);

    if (n_type_ids != n_children) {
      ArrowErrorSet(error,
                    "Expected between %" PRId64 " children for Union type with %" PRId64
                    " typeIds but found %" PRId64,
                    n_type_ids, n_type_ids, n_children);
      return EINVAL;
    }

    if (n_type_ids > 0) {
      n_chars = snprintf(format_cursor, format_out_size, "%d",
                         flatbuffers_int32_vec_at(type_ids, 0));
      format_cursor += n_chars;
      format_out_size -= n_chars;

      if (n_chars < 0) {
        ArrowErrorSet(error, "snprintf() encoding error");
        return ERANGE;
      }

      for (int64_t i = 1; i < n_type_ids; i++) {
        n_chars = snprintf(format_cursor, format_out_size, ",%" PRId32,
                           flatbuffers_int32_vec_at(type_ids, i));
        format_cursor += n_chars;
        format_out_size -= n_chars;

        if (n_chars < 0) {
          ArrowErrorSet(error, "snprintf() encoding error");
          return ERANGE;
        }
      }
    }
  } else if (n_children > 0) {
    n_chars = snprintf(format_cursor, format_out_size, "0");
    format_cursor += n_chars;
    format_out_size -= n_chars;

    if (n_chars < 0) {
      ArrowErrorSet(error, "snprintf() encoding error");
      return ERANGE;
    }

    for (int64_t i = 1; i < n_children; i++) {
      n_chars = snprintf(format_cursor, format_out_size, ",%" PRId64, i);
      format_cursor += n_chars;
      format_out_size -= n_chars;

      if (n_chars < 0) {
        ArrowErrorSet(error, "snprintf() encoding error");
        return ERANGE;
      }
    }
  }

  return ArrowIpcDecoderSetTypeSimpleNested(schema, union_types_str, error);
}

static int ArrowIpcDecoderSetType(struct ArrowSchema* schema, ns(Field_table_t) field,
                                  int64_t n_children, struct ArrowError* error) {
  int type_type = ns(Field_type_type(field));
  if (ns(Field_type_get(field)) == NULL) {
    ArrowErrorSet(error, "Field has a type of kind %d but no type table", type_type);
    return EINVAL;
  }
  switch (type_type) {
    case ns(Type_Null):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_NA, error);
    case ns(Type_Bool):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_BOOL, error);
    case ns(Type_Int):
      return ArrowIpcDecoderSetTypeInt(schema, ns(Field_type_get(field)), error);
    case ns(Type_FloatingPoint):
      return ArrowIpcDecoderSetTypeFloatingPoint(schema, ns(Field_type_get(field)),
                                                 error);
    case ns(Type_Decimal):
      return ArrowIpcDecoderSetTypeDecimal(schema, ns(Field_type_get(field)), error);
    case ns(Type_Binary):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_BINARY, error);
    case ns(Type_LargeBinary):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_LARGE_BINARY, error);
    case ns(Type_FixedSizeBinary):
      return ArrowIpcDecoderSetTypeFixedSizeBinary(schema, ns(Field_type_get(field)),
                                                   error);
    case ns(Type_BinaryView):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_BINARY_VIEW, error);
    case ns(Type_Utf8):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_STRING, error);
    case ns(Type_LargeUtf8):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_LARGE_STRING, error);
    case ns(Type_Utf8View):
      return ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_STRING_VIEW, error);
    case ns(Type_Date):
      return ArrowIpcDecoderSetTypeDate(schema, ns(Field_type_get(field)), error);
    case ns(Type_Time):
      return ArrowIpcDecoderSetTypeTime(schema, ns(Field_type_get(field)), error);
    case ns(Type_Timestamp):
      return ArrowIpcDecoderSetTypeTimestamp(schema, ns(Field_type_get(field)), error);
    case ns(Type_Duration):
      return ArrowIpcDecoderSetTypeDuration(schema, ns(Field_type_get(field)), error);
    case ns(Type_Interval):
      return ArrowIpcDecoderSetTypeInterval(schema, ns(Field_type_get(field)), error);
    case ns(Type_Struct_):
      return ArrowIpcDecoderSetTypeSimpleNested(schema, "+s", error);
    case ns(Type_List):
      return ArrowIpcDecoderSetTypeSimpleNested(schema, "+l", error);
    case ns(Type_LargeList):
      return ArrowIpcDecoderSetTypeSimpleNested(schema, "+L", error);
    case ns(Type_FixedSizeList):
      return ArrowIpcDecoderSetTypeFixedSizeList(schema, ns(Field_type_get(field)),
                                                 error);
    case ns(Type_ListView):
      return ArrowIpcDecoderSetTypeSimpleNested(schema, "+vl", error);
    case ns(Type_LargeListView):
      return ArrowIpcDecoderSetTypeSimpleNested(schema, "+vL", error);
    case ns(Type_Map):
      return ArrowIpcDecoderSetTypeMap(schema, ns(Field_type_get(field)), error);
    case ns(Type_Union):
      return ArrowIpcDecoderSetTypeUnion(schema, ns(Field_type_get(field)), n_children,
                                         error);
    case ns(Type_RunEndEncoded):
      return ArrowIpcDecoderSetTypeSimpleNested(schema, "+r", error);
    default:
      ArrowErrorSet(error, "Unrecognized Field type with value %d", type_type);
      return EINVAL;
  }
}

// When decoding dictionaries, we move the value type to the schema->dictionary
// member, but we need to move the field metadata back because in IPC there
// is no such thing as dictionary metadata (even extension metadata)
// https://github.com/apache/arrow/issues/49704
static int ArrowIpcMoveDictionaryMetadataBackToField(struct ArrowSchema* schema) {
  NANOARROW_DCHECK(schema->dictionary != NULL);
  NANOARROW_RETURN_NOT_OK(ArrowSchemaSetMetadata(schema, schema->dictionary->metadata));
  NANOARROW_RETURN_NOT_OK(ArrowSchemaSetMetadata(schema->dictionary, NULL));
  return NANOARROW_OK;
}

static int ArrowIpcSetDictionaryEncoding(
    struct ArrowSchema* schema, ns(DictionaryEncoding_table_t dictionary_encoding),
    struct ArrowIpcDictionaryEncodings* dictionaries, struct ArrowError* error) {
  switch (
      org_apache_arrow_flatbuf_DictionaryEncoding_dictionaryKind(dictionary_encoding)) {
    case ns(DictionaryKind_DenseArray):
      break;
    default:
      ArrowErrorSet(error, "Unexpected value for DictionaryKind");
      return EINVAL;
  }

  struct ArrowSchema tmp;
  ArrowSchemaMove(schema, &tmp);

  ArrowSchemaInit(schema);
  int result = ArrowSchemaAllocateDictionary(schema);
  if (result != NANOARROW_OK) {
    ArrowSchemaRelease(&tmp);
    ArrowErrorSet(error, "ArrowSchemaAllocateDictionary() failed");
    return result;
  }

  ArrowSchemaMove(&tmp, schema->dictionary);

  NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowSchemaSetName(schema, schema->dictionary->name),
                                     error);
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowSchemaSetName(schema->dictionary, ""), error);

  // indexType is optional: "If omitted, int32 is assumed" (Schema.fbs).
  if (ns(DictionaryEncoding_indexType_is_present(dictionary_encoding))) {
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderSetTypeInt(
        schema, ns(DictionaryEncoding_indexType_get(dictionary_encoding)), error));
  } else {
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcDecoderSetTypeSimple(schema, NANOARROW_TYPE_INT32, error));
  }

  if (ns(DictionaryEncoding_isOrdered_get(dictionary_encoding))) {
    schema->flags |= ARROW_FLAG_DICTIONARY_ORDERED;
  }

  // Sort out field metadata between the schema and the dictionary member
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowIpcMoveDictionaryMetadataBackToField(schema),
                                     error);

  // Track the identifier if we have a dictionaries object in which to track it
  if (dictionaries != NULL) {
    int64_t id = ns(DictionaryEncoding_id(dictionary_encoding));
    struct ArrowIpcDictionaryEncoding encoding = {
        schema, id, NANOARROW_IPC_DICTIONARY_KIND_DENSE_ARRAY};

    NANOARROW_RETURN_NOT_OK_WITH_ERROR(
        ArrowIpcDictionaryEncodingsAppend(dictionaries, encoding), error);
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetChildren(struct ArrowSchema* schema, ns(Field_vec_t) fields,
                                      struct ArrowIpcDictionaryEncodings* dictionaries,
                                      struct ArrowError* error);

static int ArrowIpcDecoderSetField(struct ArrowSchema* schema, ns(Field_table_t) field,
                                   struct ArrowIpcDictionaryEncodings* dictionaries,
                                   struct ArrowError* error) {
  int result;
  if (ns(Field_name_is_present(field))) {
    result = ArrowSchemaSetName(schema, ns(Field_name_get(field)));
  } else {
    result = ArrowSchemaSetName(schema, "");
  }

  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "ArrowSchemaSetName() failed");
    return result;
  }

  // Sets the schema->format and validates type-related inconsistencies
  // that might exist in the flatbuffer
  ns(Field_vec_t) children = ns(Field_children(field));
  int64_t n_children = ns(Field_vec_len(children));

  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderSetType(schema, field, n_children, error));

  // nanoarrow's type setters set the nullable flag by default, so we might
  // have to unset it here.
  if (ns(Field_nullable_get(field))) {
    schema->flags |= ARROW_FLAG_NULLABLE;
  } else {
    schema->flags &= ~ARROW_FLAG_NULLABLE;
  }

  // Children are defined separately in the flatbuffer, so we allocate, initialize
  // and set them separately as well.
  result = ArrowSchemaAllocateChildren(schema, n_children);
  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "ArrowSchemaAllocateChildren() failed");
    return result;
  }

  for (int64_t i = 0; i < n_children; i++) {
    ArrowSchemaInit(schema->children[i]);
  }

  NANOARROW_RETURN_NOT_OK(
      ArrowIpcDecoderSetChildren(schema, children, dictionaries, error));
  NANOARROW_RETURN_NOT_OK(
      ArrowIpcDecoderSetMetadata(schema, ns(Field_custom_metadata(field)), error));

  // If this is a dictionary encoded field, set the dictionary encoding
  if (ns(Field_dictionary_is_present(field))) {
    NANOARROW_RETURN_NOT_OK(ArrowIpcSetDictionaryEncoding(
        schema, ns(Field_dictionary(field)), dictionaries, error));
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderSetChildren(struct ArrowSchema* schema, ns(Field_vec_t) fields,
                                      struct ArrowIpcDictionaryEncodings* dictionaries,
                                      struct ArrowError* error) {
  int64_t n_fields = ns(Schema_vec_len(fields));

  for (int64_t i = 0; i < n_fields; i++) {
    ns(Field_table_t) field = ns(Field_vec_at(fields, i));
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcDecoderSetField(schema->children[i], field, dictionaries, error));
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderDecodeSchemaHeader(struct ArrowIpcDecoder* decoder,
                                             flatbuffers_generic_t message_header,
                                             struct ArrowError* error) {
  ns(Schema_table_t) schema = (ns(Schema_table_t))message_header;
  int endianness = ns(Schema_endianness(schema));
  switch (endianness) {
    case ns(Endianness_Little):
      decoder->endianness = NANOARROW_IPC_ENDIANNESS_LITTLE;
      break;
    case ns(Endianness_Big):
      decoder->endianness = NANOARROW_IPC_ENDIANNESS_BIG;
      break;
    default:
      ArrowErrorSet(error,
                    "Expected Schema endianness of 0 (little) or 1 (big) but got %d",
                    endianness);
      return EINVAL;
  }

  ns(Feature_vec_t) features = ns(Schema_features(schema));
  int64_t n_features = ns(Feature_vec_len(features));
  decoder->feature_flags = 0;

  for (int64_t i = 0; i < n_features; i++) {
    ns(Feature_enum_t) feature = ns(Feature_vec_at(features, i));
    switch (feature) {
      case ns(Feature_COMPRESSED_BODY):
        decoder->feature_flags |= NANOARROW_IPC_FEATURE_COMPRESSED_BODY;
        break;
      case ns(Feature_DICTIONARY_REPLACEMENT):
        decoder->feature_flags |= NANOARROW_IPC_FEATURE_DICTIONARY_REPLACEMENT;
        break;
      default:
        ArrowErrorSet(error, "Unrecognized Schema feature with value %d", (int)feature);
        return EINVAL;
    }
  }

  return NANOARROW_OK;
}

static int ArrowIpcDecoderDecodeDictionaryBatchHeader(
    struct ArrowIpcDecoder* decoder, flatbuffers_generic_t message_header) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  ns(DictionaryBatch_table_t) dictionary = (ns(DictionaryBatch_table_t))message_header;
  private_data->dictionary.id = ns(DictionaryBatch_id(dictionary));
  private_data->dictionary.is_delta = ns(DictionaryBatch_isDelta(dictionary));

  decoder->dictionary = &private_data->dictionary;
  return NANOARROW_OK;
}

static int ArrowIpcDecoderDecodeRecordBatchHeader(struct ArrowIpcDecoder* decoder,
                                                  flatbuffers_generic_t message_header,
                                                  struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  ns(RecordBatch_table_t) batch = (ns(RecordBatch_table_t))message_header;

  ns(FieldNode_vec_t) fields = ns(RecordBatch_nodes(batch));
  ns(Buffer_vec_t) buffers = ns(RecordBatch_buffers(batch));
  int64_t n_fields = ns(FieldNode_vec_len(fields));
  int64_t n_buffers = ns(Buffer_vec_len(buffers));

  // Check field node and buffer count. We have one more field and buffer
  // because we count the root struct and the flatbuffer message does not.
  if ((n_fields + 1) != private_data->n_fields) {
    ArrowErrorSet(error, "Expected %" PRId64 " field nodes in message but found %" PRId64,
                  private_data->n_fields - 1, n_fields);
    return EINVAL;
  }

  int64_t n_expected_buffers = private_data->n_buffers;

  // Each binary-view or string-view node adds the variadic data buffers its
  // entry in variadicBufferCounts names.
  if (ns(RecordBatch_variadicBufferCounts_is_present(batch))) {
    flatbuffers_int64_vec_t counts = ns(RecordBatch_variadicBufferCounts(batch));
    int64_t n_counts = (int64_t)flatbuffers_int64_vec_len(counts);
    if (n_counts != private_data->n_view_fields) {
      ArrowErrorSet(error,
                    "Expected %" PRId64 " variadic buffer counts in message but found %" PRId64,
                    private_data->n_view_fields, n_counts);
      return EINVAL;
    }
    for (int64_t i = 0; i < n_counts; i++) {
      int64_t count = flatbuffers_int64_vec_at(counts, (size_t)i);
      if (count < 0 || count > n_buffers) {
        ArrowErrorSet(error, "Invalid variadic buffer count %" PRId64, count);
        return EINVAL;
      }
      n_expected_buffers += count;
    }
  } else if (private_data->n_view_fields > 0) {
    ArrowErrorSet(error, "Expected variadic buffer counts for %" PRId64 " view fields",
                  private_data->n_view_fields);
    return EINVAL;
  }

  if (decoder->metadata_version < NANOARROW_IPC_METADATA_VERSION_V5) {
    // Unions had null buffers before arrow 1.0, so expect one extra buffer per union
    // field
    n_expected_buffers += private_data->n_union_fields;
  }

  if ((n_buffers + 1) != n_expected_buffers) {
    ArrowErrorSet(error, "Expected %" PRId64 " buffers in message but found %" PRId64,
                  n_expected_buffers - 1, n_buffers);
    return EINVAL;
  }

  if (ns(RecordBatch_compression_is_present(batch))) {
    ns(BodyCompression_table_t) compression = ns(RecordBatch_compression(batch));
    ns(CompressionType_enum_t) codec = ns(BodyCompression_codec(compression));
    switch (codec) {
      case ns(CompressionType_LZ4_FRAME):
        decoder->codec = NANOARROW_IPC_COMPRESSION_TYPE_LZ4_FRAME;
        break;
      case ns(CompressionType_ZSTD):
        decoder->codec = NANOARROW_IPC_COMPRESSION_TYPE_ZSTD;
        break;
      default:
        ArrowErrorSet(error, "Unrecognized RecordBatch BodyCompression codec value: %d",
                      (int)codec);
        return EINVAL;
    }
  } else {
    decoder->codec = NANOARROW_IPC_COMPRESSION_TYPE_NONE;
  }

  // Copying field node and buffer information is separate so as only to pay for the
  // nodes that are actually accessed.
  return NANOARROW_OK;
}

// Wipes any "current message" fields before moving on to a new message
static inline void ArrowIpcDecoderResetHeaderInfo(struct ArrowIpcDecoder* decoder) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  decoder->message_type = 0;
  decoder->metadata_version = 0;
  decoder->endianness = 0;
  decoder->feature_flags = 0;
  decoder->codec = 0;
  decoder->header_size_bytes = 0;
  decoder->body_size_bytes = 0;
  decoder->dictionary = NULL;
  memset(&private_data->dictionary, 0, sizeof(struct ArrowIpcDictionaryBatch));
  decoder->footer = NULL;
  ArrowIpcFooterReset(&private_data->footer);
  private_data->last_message = NULL;
}

// Returns NANOARROW_OK if data is large enough to read the first 8 bytes
// of the message header, ESPIPE if reading more data might help, or EINVAL if the content
// is not valid. Advances the input ArrowBufferView by prefix_size (8 bytes or 4 bytes if
// the message is pre-0.15 and has no continuation). Sets decoder->header_size_bytes
// to the flatbuffers length plus the prefix_size.
static inline int ArrowIpcDecoderReadHeaderPrefix(struct ArrowIpcDecoder* decoder,
                                                  struct ArrowBufferView* data_mut,
                                                  int32_t* prefix_size_bytes,
                                                  struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  if (data_mut->size_bytes < 8) {
    ArrowErrorSet(error,
                  "Expected data of at least 8 bytes but only %" PRId64 " bytes remain",
                  data_mut->size_bytes);
    return ESPIPE;
  }

  int swap_endian = private_data->system_endianness == NANOARROW_IPC_ENDIANNESS_BIG;
  int32_t continuation = ArrowIpcReadInt32LE(data_mut, swap_endian);
  int32_t length;
  if ((uint32_t)continuation != 0xFFFFFFFF) {
    if (continuation < 0) {
      ArrowErrorSet(error, "Expected 0xFFFFFFFF at start of message but found 0x%08X",
                    (unsigned int)continuation);
      return EINVAL;
    }
    // Tolerate pre-0.15 encapsulated messages which only had the length prefix
    length = continuation;
    *prefix_size_bytes = sizeof(length);
  } else {
    length = ArrowIpcReadInt32LE(data_mut, swap_endian);
    *prefix_size_bytes = sizeof(continuation) + sizeof(length);
  }
  if (length < 0) {
    ArrowErrorSet(error,
                  "Expected message size > 0 but found message size of %" PRId32 " bytes",
                  length);
    return EINVAL;
  }

  // The prefix and the length together must still fit the int32_t field.
  if (length > INT32_MAX - *prefix_size_bytes) {
    ArrowErrorSet(error, "Message size of %" PRId32 " bytes is too large", length);
    return EINVAL;
  }
  decoder->header_size_bytes = *prefix_size_bytes + length;

  if (length == 0) {
    ArrowErrorSet(error, "End of Arrow stream");
    return ENODATA;
  }

  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderPeekHeader(struct ArrowIpcDecoder* decoder,
                                         struct ArrowBufferView data,
                                         int32_t* prefix_size_bytes,
                                         struct ArrowError* error) {
  ArrowIpcDecoderResetHeaderInfo(decoder);
  NANOARROW_RETURN_NOT_OK(
      ArrowIpcDecoderReadHeaderPrefix(decoder, &data, prefix_size_bytes, error));
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderVerifyHeader(struct ArrowIpcDecoder* decoder,
                                           struct ArrowBufferView data,
                                           struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  ArrowIpcDecoderResetHeaderInfo(decoder);
  int32_t prefix_size_bytes;
  NANOARROW_RETURN_NOT_OK(
      ArrowIpcDecoderReadHeaderPrefix(decoder, &data, &prefix_size_bytes, error));

  // Check that data contains at least the entire header (return ESPIPE to signal
  // that reading more data may help).
  if (data.size_bytes < (int64_t)decoder->header_size_bytes - prefix_size_bytes) {
    ArrowErrorSet(error,
                  "Expected >= %d bytes of remaining data but found %" PRId64
                  " bytes in buffer",
                  decoder->header_size_bytes, data.size_bytes + prefix_size_bytes);
    return ESPIPE;
  }

  // Run flatbuffers verification
  enum flatcc_verify_error_no verify_error =
      ns(Message_verify_as_root(data.data.as_uint8,
                                decoder->header_size_bytes - prefix_size_bytes);
         if (verify_error != flatcc_verify_ok)) {
    ArrowErrorSet(error, "Message flatbuffer verification failed (%d) %s",
                  (int)verify_error, flatcc_verify_error_string(verify_error));
    return EINVAL;
  }

  // Read some basic information from the message
  ns(Message_table_t) message = ns(Message_as_root(data.data.as_uint8));
  decoder->metadata_version = ns(Message_version(message));
  decoder->message_type = ns(Message_header_type(message));
  decoder->body_size_bytes = ns(Message_bodyLength(message));

  private_data->last_message = ns(Message_header_get(message));
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderPeekFooter(struct ArrowIpcDecoder* decoder,
                                         struct ArrowBufferView data,
                                         struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  ArrowIpcDecoderResetHeaderInfo(decoder);
  if (data.size_bytes < (int)strlen(NANOARROW_IPC_MAGIC) + (int)sizeof(int32_t)) {
    ArrowErrorSet(error,
                  "Expected data of at least 10 bytes but only %" PRId64
                  " bytes are available",
                  data.size_bytes);
    return ESPIPE;
  }

  const char* data_end = data.data.as_char + data.size_bytes;
  const char* magic = data_end - strlen(NANOARROW_IPC_MAGIC);
  const char* footer_size_data = magic - sizeof(int32_t);

  if (memcmp(magic, NANOARROW_IPC_MAGIC, strlen(NANOARROW_IPC_MAGIC)) != 0) {
    // The input is not NUL-terminated: print the six bytes compared, not a
    // string starting one past the end of the buffer.
    ArrowErrorSet(error, "Expected file to end with ARROW1 but got %.6s", magic);
    return EINVAL;
  }

  int32_t footer_size;
  memcpy(&footer_size, footer_size_data, sizeof(footer_size));
  if (private_data->system_endianness == NANOARROW_IPC_ENDIANNESS_BIG) {
    footer_size = bswap32(footer_size);
  }

  if (footer_size < 0) {
    ArrowErrorSet(error, "Expected footer size > 0 but found footer size of %d bytes",
                  footer_size);
    return EINVAL;
  }

  decoder->header_size_bytes = footer_size;
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderVerifyFooter(struct ArrowIpcDecoder* decoder,
                                           struct ArrowBufferView data,
                                           struct ArrowError* error) {
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderPeekFooter(decoder, data, error));

  // Check that data contains at least the entire footer (return ESPIPE to signal
  // that reading more data may help).
  int32_t footer_and_size_and_magic_size =
      decoder->header_size_bytes + sizeof(int32_t) + (int)strlen(NANOARROW_IPC_MAGIC);
  if (data.size_bytes < footer_and_size_and_magic_size) {
    ArrowErrorSet(error,
                  "Expected >= %d bytes of data but only %" PRId64
                  " bytes are in the buffer",
                  footer_and_size_and_magic_size, data.size_bytes);
    return ESPIPE;
  }

  const uint8_t* footer_data =
      data.data.as_uint8 + data.size_bytes - footer_and_size_and_magic_size;

  // Run flatbuffers verification
  enum flatcc_verify_error_no verify_error =
      ns(Footer_verify_as_root(footer_data, decoder->header_size_bytes));
  if (verify_error != flatcc_verify_ok) {
    ArrowErrorSet(error, "Footer flatbuffer verification failed (%d) %s",
                  (int)verify_error, flatcc_verify_error_string(verify_error));
    return EINVAL;
  }

  // Read some basic information from the message
  ns(Footer_table_t) footer = ns(Footer_as_root(footer_data));
  if (ns(Footer_schema(footer)) == NULL) {
    ArrowErrorSet(error, "Footer has no schema");
    return EINVAL;
  }

  decoder->metadata_version = ns(Footer_version(footer));
  decoder->body_size_bytes = 0;
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderDecodeHeader(struct ArrowIpcDecoder* decoder,
                                           struct ArrowBufferView data,
                                           struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  ArrowIpcDecoderResetHeaderInfo(decoder);
  int32_t prefix_size_bytes;
  NANOARROW_RETURN_NOT_OK(
      ArrowIpcDecoderReadHeaderPrefix(decoder, &data, &prefix_size_bytes, error));

  // Check that data contains at least the entire header (return ESPIPE to signal
  // that reading more data may help).
  if (data.size_bytes < (int64_t)decoder->header_size_bytes - prefix_size_bytes) {
    ArrowErrorSet(error,
                  "Expected >= %d bytes of remaining data but found %" PRId64
                  " bytes in buffer",
                  decoder->header_size_bytes, data.size_bytes + prefix_size_bytes);
    return ESPIPE;
  }

  ns(Message_table_t) message = ns(Message_as_root(data.data.as_uint8));
  if (!message) {
    return EINVAL;
  }

  // Read some basic information from the message
  decoder->metadata_version = ns(Message_version(message));
  decoder->message_type = ns(Message_header_type(message));
  decoder->body_size_bytes = ns(Message_bodyLength(message));

  switch (decoder->metadata_version) {
    case ns(MetadataVersion_V4):
    case ns(MetadataVersion_V5):
      break;
      ArrowErrorSet(error, "Expected metadata version V4 or V5 but found %s",
                    ns(MetadataVersion_name(ns(Message_version(message)))));
      return EINVAL;
    case ns(MetadataVersion_V1):
    case ns(MetadataVersion_V2):
    case ns(MetadataVersion_V3):
    default:
      ArrowErrorSet(error, "Unexpected value for Message metadata version (%d)",
                    decoder->metadata_version);
      return EINVAL;
  }

  flatbuffers_generic_t message_header = ns(Message_header_get(message));
  if (message_header == NULL) {
    ArrowErrorSet(error, "Message has a header of kind %d but no header table",
                  (int)decoder->message_type);
    return EINVAL;
  }
  switch (decoder->message_type) {
    case ns(MessageHeader_Schema):
      NANOARROW_RETURN_NOT_OK(
          ArrowIpcDecoderDecodeSchemaHeader(decoder, message_header, error));
      break;
    case ns(MessageHeader_DictionaryBatch):
      NANOARROW_RETURN_NOT_OK(
          ArrowIpcDecoderDecodeDictionaryBatchHeader(decoder, message_header));
      break;
    case ns(MessageHeader_RecordBatch):
      NANOARROW_RETURN_NOT_OK(
          ArrowIpcDecoderDecodeRecordBatchHeader(decoder, message_header, error));
      break;
    case ns(MessageHeader_Tensor):
    case ns(MessageHeader_SparseTensor):
      ArrowErrorSet(error, "Unsupported message type: '%s'",
                    ns(MessageHeader_type_name(ns(Message_header_type(message)))));
      return ENOTSUP;
    default:
      ArrowErrorSet(error, "Unknown message type: %d", (int)(decoder->message_type));
      return EINVAL;
  }

  private_data->last_message = message_header;
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcDecoderDecodeSchemaImpl(
    ns(Schema_table_t) schema, struct ArrowSchema* out,
    struct ArrowIpcDictionaryEncodings* dictionary_encodings_out,
    struct ArrowError* error) {
  ArrowSchemaInit(out);
  // Top-level batch schema is typically non-nullable
  out->flags = 0;

  ns(Field_vec_t) fields = ns(Schema_fields(schema));
  int64_t n_fields = ns(Schema_vec_len(fields));

  ArrowErrorCode result = ArrowSchemaSetTypeStruct(out, n_fields);
  if (result != NANOARROW_OK) {
    ArrowErrorSet(error, "Failed to allocate struct schema with %" PRId64 " children",
                  n_fields);
    return result;
  }

  NANOARROW_RETURN_NOT_OK(
      ArrowIpcDecoderSetChildren(out, fields, dictionary_encodings_out, error));
  NANOARROW_RETURN_NOT_OK(
      ArrowIpcDecoderSetMetadata(out, ns(Schema_custom_metadata(schema)), error));
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderDecodeSchemaWithDictionaries(
    struct ArrowIpcDecoder* decoder, struct ArrowSchema* out,
    struct ArrowIpcDictionaryEncodings* dictionary_encodings_out,
    struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  if (private_data->last_message == NULL ||
      decoder->message_type != NANOARROW_IPC_MESSAGE_TYPE_SCHEMA) {
    ArrowErrorSet(error, "decoder did not just decode a Schema message");
    return EINVAL;
  }

  if (dictionary_encodings_out != NULL) {
    ArrowIpcDictionaryEncodingsInit(dictionary_encodings_out);
  }

  struct ArrowSchema tmp;
  ArrowErrorCode result =
      ArrowIpcDecoderDecodeSchemaImpl((ns(Schema_table_t))private_data->last_message,
                                      &tmp, dictionary_encodings_out, error);

  if (result != NANOARROW_OK) {
    ArrowSchemaRelease(&tmp);

    if (dictionary_encodings_out != NULL) {
      ArrowIpcDictionaryEncodingsReset(dictionary_encodings_out);
    }

    return result;
  }
  ArrowSchemaMove(&tmp, out);
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderDecodeSchema(struct ArrowIpcDecoder* decoder,
                                           struct ArrowSchema* out,
                                           struct ArrowError* error) {
  return ArrowIpcDecoderDecodeSchemaWithDictionaries(decoder, out, NULL, error);
}

ArrowErrorCode ArrowIpcDecoderDecodeFooter(struct ArrowIpcDecoder* decoder,
                                           struct ArrowBufferView data,
                                           struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  int32_t footer_and_size_and_magic_size =
      decoder->header_size_bytes + sizeof(int32_t) + (int)strlen(NANOARROW_IPC_MAGIC);
  const uint8_t* footer_data =
      data.data.as_uint8 + data.size_bytes - footer_and_size_and_magic_size;
  ns(Footer_table_t) footer = ns(Footer_as_root(footer_data));
  if (footer == NULL || ns(Footer_schema(footer)) == NULL) {
    ArrowErrorSet(error, "Footer has no schema");
    return EINVAL;
  }

  NANOARROW_RETURN_NOT_OK(
      ArrowIpcDecoderDecodeSchemaHeader(decoder, ns(Footer_schema(footer)), error));

  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderDecodeSchemaImpl(
      ns(Footer_schema(footer)), &private_data->footer.schema,
      &private_data->footer.dictionaries, error));

  ns(Block_vec_t) blocks = ns(Footer_recordBatches(footer));
  int64_t n = ns(Block_vec_len(blocks));
  NANOARROW_RETURN_NOT_OK(ArrowBufferResize(&private_data->footer.record_batch_blocks,
                                            sizeof(struct ArrowIpcFileBlock) * n,
                                            /*shrink_to_fit=*/0));
  struct ArrowIpcFileBlock* record_batches =
      (struct ArrowIpcFileBlock*)private_data->footer.record_batch_blocks.data;
  for (int64_t i = 0; i < n; i++) {
    record_batches[i].offset = ns(Block_offset(blocks + i));
    record_batches[i].metadata_length = ns(Block_metaDataLength(blocks + i));
    record_batches[i].body_length = ns(Block_bodyLength(blocks + i));
  }

  blocks = ns(Footer_dictionaries(footer));
  n = ns(Block_vec_len(blocks));
  NANOARROW_RETURN_NOT_OK(ArrowBufferResize(&private_data->footer.dictionary_blocks,
                                            sizeof(struct ArrowIpcFileBlock) * n,
                                            /*shrink_to_fit=*/0));
  struct ArrowIpcFileBlock* dictionaries =
      (struct ArrowIpcFileBlock*)private_data->footer.dictionary_blocks.data;
  for (int64_t i = 0; i < n; i++) {
    dictionaries[i].offset = ns(Block_offset(blocks + i));
    dictionaries[i].metadata_length = ns(Block_metaDataLength(blocks + i));
    dictionaries[i].body_length = ns(Block_bodyLength(blocks + i));
  }

  decoder->footer = &private_data->footer;
  return NANOARROW_OK;
}

static void ArrowIpcDecoderCountFields(const struct ArrowSchema* schema,
                                       int64_t* n_fields) {
  *n_fields += 1;
  for (int64_t i = 0; i < schema->n_children; i++) {
    ArrowIpcDecoderCountFields(schema->children[i], n_fields);
  }
}

static ArrowErrorCode ArrowIpcDecoderInitFields(
    struct ArrowIpcField* fields, const struct ArrowSchema* schema,
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    struct ArrowArrayView* array_view, struct ArrowArray* array, int64_t* n_fields,
    int64_t* n_buffers, int64_t* n_union_fields, int64_t* n_view_fields,
    struct ArrowError* error) {
  struct ArrowIpcField* field = fields + (*n_fields);
  field->array_view = array_view;
  field->array = array;
  field->buffer_offset = *n_buffers;
  field->dictionary_id = NANOARROW_IPC_NO_DICTIONARY_ID;
  field->view_index = *n_view_fields;
  *n_view_fields += array_view->storage_type == NANOARROW_TYPE_BINARY_VIEW ||
                    array_view->storage_type == NANOARROW_TYPE_STRING_VIEW;

  if (schema->dictionary != NULL) {
    if (dictionary_encodings == NULL) {
      const char* name = schema->name;
      if (name == NULL) {
        name = "<unnamed field>";
      }

      ArrowErrorSet(error,
                    "Can't resolve dictionary ID for field '%s' (dictionary encodings "
                    "not provided)",
                    name);
      return EINVAL;
    }

    const struct ArrowIpcDictionaryEncoding* dictionary_encoding =
        ArrowIpcDictionaryEncodingsFind(dictionary_encodings, schema);
    if (dictionary_encoding == NULL) {
      const char* name = schema->name;
      if (name == NULL) {
        name = "<unnamed field>";
      }

      ArrowErrorSet(error, "Can't resolve dictionary ID for field '%s'", name);
      return EINVAL;
    }

    field->dictionary_id = dictionary_encoding->id;
  }

  for (int i = 0; i < NANOARROW_MAX_FIXED_BUFFERS; i++) {
    *n_buffers += array_view->layout.buffer_type[i] != NANOARROW_BUFFER_TYPE_NONE;
  }
  *n_union_fields += array_view->storage_type == NANOARROW_TYPE_SPARSE_UNION ||
                     array_view->storage_type == NANOARROW_TYPE_DENSE_UNION;

  *n_fields += 1;

  for (int64_t i = 0; i < array_view->n_children; i++) {
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderInitFields(
        fields, schema->children[i], dictionary_encodings, array_view->children[i],
        array->children[i], n_fields, n_buffers, n_union_fields, n_view_fields, error));
  }

  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderSetSchemaWithDictionaries(
    struct ArrowIpcDecoder* decoder, const struct ArrowSchema* schema,
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  // Reset previously allocated schema-specific resources
  private_data->n_buffers = 0;
  private_data->n_fields = 0;
  private_data->n_union_fields = 0;
  private_data->n_view_fields = 0;
  ArrowArrayViewReset(&private_data->array_view);
  if (private_data->array.release != NULL) {
    ArrowArrayRelease(&private_data->array);
  }
  if (private_data->fields != NULL) {
    ArrowFree(private_data->fields);
  }

  // Allocate Array and ArrayView based on schema without moving the schema.
  // This will fail if the schema is not valid.
  NANOARROW_RETURN_NOT_OK(
      ArrowArrayViewInitFromSchema(&private_data->array_view, schema, error));
  NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromArrayView(&private_data->array,
                                                      &private_data->array_view, error));

  // Root must be a struct
  if (private_data->array_view.storage_type != NANOARROW_TYPE_STRUCT) {
    ArrowErrorSet(error, "schema must be a struct type");
    return EINVAL;
  }

  // Walk tree and calculate how many fields we need to allocate
  ArrowIpcDecoderCountFields(schema, &private_data->n_fields);
  private_data->fields = (struct ArrowIpcField*)ArrowMalloc(private_data->n_fields *
                                                            sizeof(struct ArrowIpcField));
  if (private_data->fields == NULL) {
    ArrowErrorSet(error, "Failed to allocate decoder->fields");
    return ENOMEM;
  }
  memset(private_data->fields, 0, private_data->n_fields * sizeof(struct ArrowIpcField));

  // Init field information and calculate starting buffer offset for each
  int64_t field_i = 0;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderInitFields(
      private_data->fields, schema, dictionary_encodings, &private_data->array_view,
      &private_data->array, &field_i, &private_data->n_buffers,
      &private_data->n_union_fields, &private_data->n_view_fields, error));

  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderSetSchema(struct ArrowIpcDecoder* decoder,
                                        const struct ArrowSchema* schema,
                                        struct ArrowError* error) {
  return ArrowIpcDecoderSetSchemaWithDictionaries(decoder, schema, NULL, error);
}

ArrowErrorCode ArrowIpcDecoderSetEndianness(struct ArrowIpcDecoder* decoder,
                                            enum ArrowIpcEndianness endianness) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  switch (endianness) {
    case NANOARROW_IPC_ENDIANNESS_UNINITIALIZED:
    case NANOARROW_IPC_ENDIANNESS_LITTLE:
    case NANOARROW_IPC_ENDIANNESS_BIG:
      private_data->endianness = endianness;
      return NANOARROW_OK;
    default:
      return EINVAL;
  }
}

/// \brief Information required to read and/or decompress a single buffer
///
/// The RecordBatch message header contains a description of each buffer
/// in the message body. The ArrowIpcBufferSource is the parsed result of
/// a single buffer with compression and endian information such that the
/// original buffer can be reconstructed.
struct ArrowIpcBufferSource {
  int64_t body_offset_bytes;
  int64_t buffer_length_bytes;
  enum ArrowIpcCompressionType codec;
  enum ArrowType data_type;
  int64_t element_size_bits;
  int swap_endian;
};

/// \brief Materializing ArrowBuffer objects
///
/// Given a description of where a buffer is located inside the message body, make
/// the ArrowBuffer that will be placed into the correct ArrowArray. The decoder
/// does not do any IO and does not make any assumptions about how or if the body
/// has been read into memory. This abstraction is currently internal and exists
/// to support the two obvious ways a user might go about this: (1) using a
/// non-owned view of memory that must be copied slice-wise or (2) adding a reference
/// to an ArrowBuffer (shared buffer) and returning a slice of that memory.
struct ArrowIpcBufferFactory {
  /// \brief User-defined callback to populate a buffer view
  ///
  /// At the time that this callback is called, the ArrowIpcBufferSource has been checked
  /// to ensure that it is within the body size declared by the message header. A
  /// possibly preallocated ArrowBuffer (dst) is provided, which implementations must use
  /// if an allocation is required (in which case the view must be populated pointing to
  /// the contents of the ArrowBuffer) If NANOARROW_OK is not returned, error must contain
  /// a null-terminated message.
  ArrowErrorCode (*make_buffer)(struct ArrowIpcBufferFactory* factory,
                                struct ArrowIpcBufferSource* src,
                                struct ArrowBufferView* dst_view, struct ArrowBuffer* dst,
                                struct ArrowError* error);

  /// \brief Caller provided decompressor instance to which any decompression requests
  /// should be made.
  struct ArrowIpcDecompressor* decompressor;

  /// \brief Buffer factory provided buffer length
  ///
  /// Rather than use the body length declared by the flatbuffer message, this is the
  /// length that should be used to check the bounds of a buffer source (i.e., this is
  /// the actual available length as opposed to the theoretical length).
  int64_t buffer_length;

  /// \brief User-defined private data to be used in the callback.
  ///
  /// Usually this would be a description of where the body has been read into memory or
  /// information required to do so.
  void* private_data;
};

static ArrowErrorCode ArrowIpcDecompressBufferFromView(
    struct ArrowIpcDecompressor* decompressor,
    enum ArrowIpcCompressionType compression_type, struct ArrowBufferView src,
    struct ArrowBuffer* dst, int* needs_decompression, struct ArrowError* error) {
  if (src.size_bytes < (int64_t)sizeof(int64_t)) {
    ArrowErrorSet(
        error,
        "Buffer size must be >= sizeof(int64_t) when buffer compression is enabled");
    return EINVAL;
  }

  // When body compression is enabled, buffers are prefixed with a little endian
  // signed 64-bit integer that is the uncompressed body length.
  int64_t uncompressed_size;
  memcpy(&uncompressed_size, src.data.data, sizeof(int64_t));
  if (ArrowIpcSystemEndianness() != NANOARROW_IPC_ENDIANNESS_LITTLE) {
    uncompressed_size = (int64_t)bswap64(uncompressed_size);
  }

  // Sentinel for "body compression was enabled but this buffer is not compressed" is -1
  if (uncompressed_size == -1) {
    *needs_decompression = 0;
    return NANOARROW_OK;
  }

  if (uncompressed_size < 0) {
    ArrowErrorSet(error,
                  "Decompressed buffer size must be -1 or >= 0 bytes but was %" PRId64,
                  uncompressed_size);
    return EINVAL;
  }

  // Prepare the source and destination
  src.data.as_uint8 += sizeof(int64_t);
  src.size_bytes -= sizeof(int64_t);
  NANOARROW_RETURN_NOT_OK(ArrowBufferResize(dst, uncompressed_size, 0));

  // Add the task to the decompressor (this may execute synchronously for some
  // decompressors)
  NANOARROW_RETURN_NOT_OK(decompressor->decompress_add(
      decompressor, compression_type, src, dst->data, uncompressed_size, error));

  // Pass on that we handled the decompression
  *needs_decompression = 1;
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcMakeBufferFromView(struct ArrowIpcBufferFactory* factory,
                                                 struct ArrowIpcBufferSource* src,
                                                 struct ArrowBufferView* dst_view,
                                                 struct ArrowBuffer* dst,
                                                 struct ArrowError* error) {
  struct ArrowBufferView* body = (struct ArrowBufferView*)factory->private_data;

  struct ArrowBufferView src_view;
  src_view.data.as_uint8 = body->data.as_uint8 + src->body_offset_bytes;
  src_view.size_bytes = src->buffer_length_bytes;

  int needs_decompression = 0;
  int uncompressed_data_offset = 0;
  if (src->codec != NANOARROW_IPC_COMPRESSION_TYPE_NONE) {
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecompressBufferFromView(
        factory->decompressor, src->codec, src_view, dst, &needs_decompression, error));
    uncompressed_data_offset += sizeof(int64_t);
  }

  if (!needs_decompression) {
    *dst_view = src_view;
    dst_view->data.as_uint8 += uncompressed_data_offset;
    dst_view->size_bytes -= uncompressed_data_offset;
  } else {
    dst_view->data.data = dst->data;
    dst_view->size_bytes = dst->size_bytes;
  }

  return NANOARROW_OK;
}

static struct ArrowIpcBufferFactory ArrowIpcBufferFactoryFromView(
    struct ArrowBufferView* buffer_view) {
  struct ArrowIpcBufferFactory out;
  out.make_buffer = &ArrowIpcMakeBufferFromView;
  out.decompressor = NULL;
  out.buffer_length = buffer_view->size_bytes;
  out.private_data = buffer_view;
  return out;
}

static ArrowErrorCode ArrowIpcMakeBufferFromShared(struct ArrowIpcBufferFactory* factory,
                                                   struct ArrowIpcBufferSource* src,
                                                   struct ArrowBufferView* dst_view,
                                                   struct ArrowBuffer* dst,
                                                   struct ArrowError* error) {
  struct ArrowBuffer* shared = (struct ArrowBuffer*)factory->private_data;

  int needs_decompression = 0;
  int uncompressed_data_offset = 0;
  if (src->codec != NANOARROW_IPC_COMPRESSION_TYPE_NONE) {
    struct ArrowBufferView src_view;
    src_view.data.as_uint8 = shared->data + src->body_offset_bytes;
    src_view.size_bytes = src->buffer_length_bytes;
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecompressBufferFromView(
        factory->decompressor, src->codec, src_view, dst, &needs_decompression, error));
    uncompressed_data_offset += sizeof(int64_t);
  }

  if (!needs_decompression) {
    ArrowBufferReset(dst);
    NANOARROW_RETURN_NOT_OK(ArrowSharedBufferClone(shared, dst));
    dst->data += src->body_offset_bytes + uncompressed_data_offset;
    dst->size_bytes = src->buffer_length_bytes - uncompressed_data_offset;
  }

  dst_view->data.data = dst->data;
  dst_view->size_bytes = dst->size_bytes;
  return NANOARROW_OK;
}

static struct ArrowIpcBufferFactory ArrowIpcBufferFactoryFromShared(
    struct ArrowBuffer* shared) {
  struct ArrowIpcBufferFactory out;
  out.make_buffer = &ArrowIpcMakeBufferFromShared;
  out.decompressor = NULL;
  out.buffer_length = shared->size_bytes;
  out.private_data = shared;
  return out;
}

// Just for the purposes of endian-swapping
struct ArrowIpcIntervalMonthDayNano {
  uint32_t months;
  uint32_t days;
  uint64_t ns;
};

static int ArrowIpcDecoderSwapEndian(struct ArrowIpcBufferSource* src,
                                     struct ArrowBufferView* out_view,
                                     struct ArrowBuffer* dst, struct ArrowError* error) {
  NANOARROW_DCHECK(out_view->size_bytes > 0);
  NANOARROW_DCHECK(out_view->data.data != NULL);

  // Some buffer data types don't need any endian swapping
  switch (src->data_type) {
    case NANOARROW_TYPE_BOOL:
    case NANOARROW_TYPE_INT8:
    case NANOARROW_TYPE_UINT8:
    case NANOARROW_TYPE_STRING:
    case NANOARROW_TYPE_BINARY:
      return NANOARROW_OK;
    default:
      break;
  }

  // Make sure dst is not a shared buffer that we can't modify
  struct ArrowBuffer tmp;
  ArrowBufferInit(&tmp);

  if (dst->allocator.private_data != NULL) {
    ArrowBufferMove(dst, &tmp);
    ArrowBufferInit(dst);
  }

  if (dst->size_bytes == 0) {
    NANOARROW_RETURN_NOT_OK(ArrowBufferReserve(dst, out_view->size_bytes));
    dst->size_bytes = out_view->size_bytes;
  }

  switch (src->data_type) {
    case NANOARROW_TYPE_DECIMAL32: {
      uint32_t* ptr = (uint32_t*)dst->data;
      for (int64_t i = 0; i < (dst->size_bytes / 4); i++) {
        ptr[i] = bswap32(out_view->data.as_uint32[i]);
      }
      break;
    }
    case NANOARROW_TYPE_DECIMAL64:
    case NANOARROW_TYPE_DECIMAL128:
    case NANOARROW_TYPE_DECIMAL256: {
      const uint64_t* ptr_src = out_view->data.as_uint64;
      uint64_t* ptr_dst = (uint64_t*)dst->data;
      uint64_t words[4];
      int n_words = (int)(src->element_size_bits / 64);
      NANOARROW_DCHECK(n_words == 1 || n_words == 2 || n_words == 4);

      for (int64_t i = 0; i < (dst->size_bytes / n_words / 8); i++) {
        for (int j = 0; j < n_words; j++) {
          words[j] = bswap64(ptr_src[i * n_words + j]);
        }

        for (int j = 0; j < n_words; j++) {
          ptr_dst[i * n_words + j] = words[n_words - j - 1];
        }
      }
      break;
    }
    case NANOARROW_TYPE_INTERVAL_DAY_TIME: {
      uint32_t* ptr = (uint32_t*)dst->data;
      for (int64_t i = 0; i < (dst->size_bytes / 4); i++) {
        ptr[i] = bswap32(out_view->data.as_uint32[i]);
      }
      break;
    }
    case NANOARROW_TYPE_INTERVAL_MONTH_DAY_NANO: {
      const uint8_t* ptr_src = out_view->data.as_uint8;
      uint8_t* ptr_dst = dst->data;
      int item_size_bytes = 16;
      struct ArrowIpcIntervalMonthDayNano item;
      for (int64_t i = 0; i < (dst->size_bytes / item_size_bytes); i++) {
        memcpy(&item, ptr_src + i * item_size_bytes, item_size_bytes);
        item.months = bswap32(item.months);
        item.days = bswap32(item.days);
        item.ns = bswap64(item.ns);
        memcpy(ptr_dst + i * item_size_bytes, &item, item_size_bytes);
      }
      break;
    }
    default:
      switch (src->element_size_bits) {
        case 16: {
          uint16_t* ptr = (uint16_t*)dst->data;
          for (int64_t i = 0; i < (dst->size_bytes / 2); i++) {
            ptr[i] = bswap16(out_view->data.as_uint16[i]);
          }
          break;
        }
        case 32: {
          uint32_t* ptr = (uint32_t*)dst->data;
          for (int64_t i = 0; i < (dst->size_bytes / 4); i++) {
            ptr[i] = bswap32(out_view->data.as_uint32[i]);
          }
          break;
        }
        case 64: {
          uint64_t* ptr = (uint64_t*)dst->data;
          for (int64_t i = 0; i < (dst->size_bytes / 8); i++) {
            ptr[i] = bswap64(out_view->data.as_uint64[i]);
          }
          break;
        }
        default:
          ArrowErrorSet(
              error, "Endian swapping for element bitwidth %" PRId64 " is not supported",
              src->element_size_bits);
          return ENOTSUP;
      }
      break;
  }

  ArrowBufferReset(&tmp);
  out_view->data.data = dst->data;
  return NANOARROW_OK;
}

struct ArrowIpcArraySetter {
  ns(FieldNode_vec_t) fields;
  int64_t field_i;
  ns(Buffer_vec_t) buffers;
  int64_t buffer_i;
  struct ArrowIpcBufferSource src;
  struct ArrowIpcBufferFactory factory;
  enum ArrowIpcMetadataVersion version;
  struct ArrowIpcDictionaries* dictionaries;
  // RecordBatch.variadicBufferCounts (NULL when absent) and the next entry
  flatbuffers_int64_vec_t variadic_counts;
  int64_t variadic_i;
};

static int ArrowIpcDecoderMakeBuffer(struct ArrowIpcArraySetter* setter, int64_t offset,
                                     int64_t length, struct ArrowBufferView* out_view,
                                     struct ArrowBuffer* out, struct ArrowError* error) {
  out_view->data.data = NULL;
  out_view->size_bytes = 0;

  if (length == 0) {
    return NANOARROW_OK;
  }

  // Check that this buffer fits within the body
  int64_t buffer_start = offset;
  int64_t buffer_end = buffer_start + length;
  if (buffer_start < 0 || buffer_end > setter->factory.buffer_length) {
    ArrowErrorSet(error,
                  "Buffer requires body offsets [%" PRId64 "..%" PRId64
                  ") but body has size %" PRId64,
                  buffer_start, buffer_end, setter->factory.buffer_length);
    return EINVAL;
  }

  setter->src.body_offset_bytes = offset;
  setter->src.buffer_length_bytes = length;
  NANOARROW_RETURN_NOT_OK(
      setter->factory.make_buffer(&setter->factory, &setter->src, out_view, out, error));

  if (setter->src.swap_endian) {
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcDecoderSwapEndian(&setter->src, out_view, out, error));
  }

  return NANOARROW_OK;
}

static int ArrowIpcIsViewType(enum ArrowType type) {
  return type == NANOARROW_TYPE_BINARY_VIEW || type == NANOARROW_TYPE_STRING_VIEW;
}

static int ArrowIpcDecoderWalkGetArray(struct ArrowArrayView* array_view,
                                       struct ArrowArray* array, struct ArrowArray* out,
                                       struct ArrowError* error) {
  out->length = array_view->length;
  out->null_count = array_view->null_count;

  // A view node's variadic buffers and sizes come after its fixed buffers.
  int is_view = ArrowIpcIsViewType(array_view->storage_type);
  int64_t n_fixed = is_view ? NANOARROW_BINARY_VIEW_FIXED_BUFFERS : array->n_buffers;
  if (is_view && array_view->n_variadic_buffers > ArrowArrayVariadicBufferCount(out)) {
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(
        ArrowArrayAddVariadicBuffers(out, array_view->n_variadic_buffers -
                                              ArrowArrayVariadicBufferCount(out)),
        error);
  }

  for (int64_t i = 0; i < n_fixed + (is_view ? array_view->n_variadic_buffers : 0);
       i++) {
    struct ArrowBufferView view;
    if (i < n_fixed) {
      view = array_view->buffer_views[i];
    } else {
      view.data.data = array_view->variadic_buffers[i - n_fixed];
      view.size_bytes = array_view->variadic_buffer_sizes[i - n_fixed];
    }
    struct ArrowBuffer* scratch_buffer = ArrowArrayBuffer(array, i);
    struct ArrowBuffer* buffer_out = ArrowArrayBuffer(out, i);

    // If the scratch buffer was used, move it to the final array. Otherwise,
    // copy the view.
    if (scratch_buffer->size_bytes == 0) {
      NANOARROW_RETURN_NOT_OK(ArrowBufferAppendBufferView(buffer_out, view));
    } else if (scratch_buffer->data == view.data.as_uint8) {
      ArrowBufferMove(scratch_buffer, buffer_out);
    } else {
      ArrowErrorSet(
          error,
          "Internal: scratch buffer was used but doesn't point to the same data as view");
      return EINVAL;
    }
  }

  for (int64_t i = 0; i < array->n_children; i++) {
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderWalkGetArray(
        array_view->children[i], array->children[i], out->children[i], error));
  }

  if (array_view->dictionary != NULL) {
    // Release the dictionary that was pre-initialized by ArrowArrayInitFromArrayView
    if (out->dictionary->release != NULL) {
      ArrowArrayRelease(out->dictionary);
    }
    // Move the pre-cloned shared dictionary to output (avoids copying)
    ArrowArrayMove(array->dictionary, out->dictionary);
  }

  return NANOARROW_OK;
}

// Reads the variadic data buffers of a binary-view or string-view node into the
// scratch array and points the array view at them.
static int ArrowIpcDecoderWalkSetVariadic(struct ArrowIpcArraySetter* setter,
                                          struct ArrowArrayView* array_view,
                                          struct ArrowArray* array,
                                          struct ArrowError* error) {
  int64_t n = 0;
  if (setter->variadic_counts != NULL) {
    n = flatbuffers_int64_vec_at(setter->variadic_counts, (size_t)setter->variadic_i);
  }
  setter->variadic_i += 1;

  int32_t have = ArrowArrayVariadicBufferCount(array);
  if (have < n) {
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(
        ArrowArrayAddVariadicBuffers(array, (int32_t)(n - have)), error);
  }
  struct ArrowArrayPrivateData* array_private =
      (struct ArrowArrayPrivateData*)array->private_data;
  struct ArrowBuffer* sizes = ArrowArrayBuffer(array, array->n_buffers - 1);
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowBufferResize(sizes, (n > 0 ? n : 1) * (int64_t)sizeof(int64_t), 0), error);

  for (int64_t k = 0; k < n; k++) {
    ns(Buffer_struct_t) buffer =
        ns(Buffer_vec_at(setter->buffers, (size_t)setter->buffer_i));
    setter->buffer_i += 1;
    struct ArrowBuffer* buffer_dst = ArrowArrayBuffer(array, 2 + k);
    if (buffer_dst->allocator.private_data != NULL) {
      ArrowBufferReset(buffer_dst);
    } else {
      buffer_dst->size_bytes = 0;
    }
    setter->src.data_type = NANOARROW_TYPE_UINT8;
    setter->src.element_size_bits = 8;
    struct ArrowBufferView view;
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderMakeBuffer(setter, ns(Buffer_offset(buffer)),
                                                      ns(Buffer_length(buffer)), &view,
                                                      buffer_dst, error));
    array_private->buffer_data[NANOARROW_BINARY_VIEW_FIXED_BUFFERS + k] = view.data.data;
    ((int64_t*)sizes->data)[k] = view.size_bytes;
  }

  array_view->n_variadic_buffers = (int32_t)n;
  array_view->variadic_buffers =
      array_private->buffer_data + NANOARROW_BINARY_VIEW_FIXED_BUFFERS;
  array_view->variadic_buffer_sizes = (int64_t*)sizes->data;
  return NANOARROW_OK;
}

static int ArrowIpcDecoderWalkSetArrayView(struct ArrowIpcDecoder* decoder,
                                           struct ArrowIpcArraySetter* setter,
                                           struct ArrowArrayView* array_view,
                                           struct ArrowArray* array,
                                           struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  // setter->field_i indexes the flatbuffer FieldNode vector (which excludes the root
  // struct), but private_data->fields includes the root at index 0, so add 1.
  struct ArrowIpcField* ipc_field = private_data->fields + setter->field_i + 1;
  if (ipc_field->dictionary_id != NANOARROW_IPC_NO_DICTIONARY_ID) {
    if (setter->dictionaries == NULL) {
      ArrowErrorSet(
          error, "Can't decode a dictionary-encoded field without ArrowIpcDictionaries");
      return ENOTSUP;
    }

    const struct ArrowArray* dictionary;
    NANOARROW_RETURN_NOT_OK(ArrowIpcDictionariesFindCurrentValue(
        setter->dictionaries, ipc_field->dictionary_id, &dictionary, error));

    if (dictionary->release == NULL) {
      ArrowErrorSet(error, "Dictionary with ID %" PRId64 " is marked as released",
                    ipc_field->dictionary_id);
      return EINVAL;
    }

    // Set the dictionary array view from the value. We may be able to skip this
    // if we can somehow detect that the dictionary hasn't changed since the last
    // decode.
    NANOARROW_RETURN_NOT_OK(
        ArrowArrayViewSetArray(array_view->dictionary, dictionary, error));

    // Clone the shared dictionary for output (avoids copying dictionary data)
    if (array->dictionary != NULL) {
      if (array->dictionary->release != NULL) {
        ArrowArrayRelease(array->dictionary);
      }
      int clone_result =
          ArrowArrayCloneShared((struct ArrowArray*)dictionary, array->dictionary);
      if (clone_result != NANOARROW_OK) {
        ArrowErrorSet(error,
                      "Failed to clone shared dictionary with ID %" PRId64
                      " (dictionary may not be shared)",
                      ipc_field->dictionary_id);
        return clone_result;
      }
    }
  }

  ns(FieldNode_struct_t) field =
      ns(FieldNode_vec_at(setter->fields, (size_t)setter->field_i));
  array_view->length = ns(FieldNode_length(field));
  array_view->null_count = ns(FieldNode_null_count(field));
  setter->field_i += 1;

  if (array_view->storage_type == NANOARROW_TYPE_SPARSE_UNION ||
      array_view->storage_type == NANOARROW_TYPE_DENSE_UNION) {
    if (setter->version < NANOARROW_IPC_METADATA_VERSION_V5) {
      ns(Buffer_struct_t) buffer =
          ns(Buffer_vec_at(setter->buffers, (size_t)setter->buffer_i));
      if (ns(Buffer_length(buffer)) != 0) {
        ArrowErrorSet(error,
                      "Cannot read pre-1.0.0 Union array with top-level validity bitmap");
        return EINVAL;
      }
      // skip the empty validity bitmap
      setter->buffer_i += 1;
    }
  }

  for (int i = 0; i < NANOARROW_MAX_FIXED_BUFFERS; i++) {
    if (array_view->layout.buffer_type[i] == NANOARROW_BUFFER_TYPE_NONE) {
      break;
    }

    ns(Buffer_struct_t) buffer =
        ns(Buffer_vec_at(setter->buffers, (size_t)setter->buffer_i));
    int64_t buffer_offset = ns(Buffer_offset(buffer));
    int64_t buffer_length = ns(Buffer_length(buffer));
    setter->buffer_i += 1;

    // Provide a buffer that will be used if any allocation has to occur
    struct ArrowBuffer* buffer_dst = ArrowArrayBuffer(array, i);

    // Attempt to re-use any previous allocation unless this buffer is
    // wrapping a custom allocator.
    if (buffer_dst->allocator.private_data != NULL) {
      ArrowBufferReset(buffer_dst);
    } else {
      buffer_dst->size_bytes = 0;
    }

    setter->src.data_type = array_view->layout.buffer_data_type[i];
    setter->src.element_size_bits = array_view->layout.element_size_bits[i];

    NANOARROW_RETURN_NOT_OK(
        ArrowIpcDecoderMakeBuffer(setter, buffer_offset, buffer_length,
                                  &array_view->buffer_views[i], buffer_dst, error));
  }

  if (ArrowIpcIsViewType(array_view->storage_type)) {
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcDecoderWalkSetVariadic(setter, array_view, array, error));
  }

  for (int64_t i = 0; i < array_view->n_children; i++) {
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderWalkSetArrayView(
        decoder, setter, array_view->children[i], array->children[i], error));
  }

  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcDecoderDecodeArrayInternal(
    struct ArrowIpcDecoder* decoder, int64_t field_i, struct ArrowArray* out,
    enum ArrowValidationLevel validation_level, struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  struct ArrowIpcField* root = private_data->fields + field_i + 1;

  if (field_i == -1) {
    NANOARROW_RETURN_NOT_OK(
        ArrowArrayInitFromArrayView(out, &private_data->array_view, error));
    out->length = private_data->array_view.length;
    out->null_count = private_data->array_view.null_count;

    for (int64_t i = 0; i < private_data->array_view.n_children; i++) {
      NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderWalkGetArray(
          private_data->array_view.children[i], private_data->array.children[i],
          out->children[i], error));
    }

  } else {
    NANOARROW_RETURN_NOT_OK(ArrowArrayInitFromArrayView(out, root->array_view, error));
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcDecoderWalkGetArray(root->array_view, root->array, out, error));
  }

  // If validation is going to happen it has already occurred; however, the part of
  // ArrowArrayFinishBuilding() that allocates a data buffer if the data buffer is
  // NULL (required for compatibility with Arrow <= 9.0.0) assumes CPU data access
  // and thus needs a validation level >= default.
  if (validation_level >= NANOARROW_VALIDATION_LEVEL_DEFAULT) {
    NANOARROW_RETURN_NOT_OK(
        ArrowArrayFinishBuilding(out, NANOARROW_VALIDATION_LEVEL_DEFAULT, error));
  } else {
    NANOARROW_RETURN_NOT_OK(
        ArrowArrayFinishBuilding(out, NANOARROW_VALIDATION_LEVEL_NONE, error));
  }

  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcDecoderDecodeArrayViewInternal(
    struct ArrowIpcDecoder* decoder, struct ArrowIpcBufferFactory factory,
    int64_t field_i, struct ArrowIpcDictionaries* dictionaries,
    struct ArrowArrayView** out_view, struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  // RecordBatch messages don't count the root node but decoder->fields does
  // (decoder->fields[0] is the root field)
  if (field_i + 1 >= private_data->n_fields) {
    ArrowErrorSet(error, "cannot decode column %" PRId64 "; there are only %" PRId64,
                  field_i, private_data->n_fields - 1);
    return EINVAL;
  }

  ns(RecordBatch_table_t) batch = (ns(RecordBatch_table_t))private_data->last_message;

  struct ArrowIpcField* root = private_data->fields + field_i + 1;

  struct ArrowIpcArraySetter setter;
  setter.fields = ns(RecordBatch_nodes(batch));
  setter.field_i = field_i;
  setter.buffers = ns(RecordBatch_buffers(batch));
  setter.buffer_i = root->buffer_offset - 1;
  setter.factory = factory;
  setter.src.codec = decoder->codec;
  setter.src.swap_endian = ArrowIpcDecoderNeedsSwapEndian(decoder);
  setter.version = decoder->metadata_version;
  setter.dictionaries = dictionaries;
  setter.variadic_counts = ns(RecordBatch_variadicBufferCounts_is_present(batch))
                               ? ns(RecordBatch_variadicBufferCounts(batch))
                               : NULL;
  setter.variadic_i = root->view_index;
  // The variadic buffers of the view nodes before the root precede its buffers.
  for (int64_t i = 0; setter.variadic_counts != NULL && i < root->view_index; i++) {
    setter.buffer_i += flatbuffers_int64_vec_at(setter.variadic_counts, (size_t)i);
  }

  // If we are going to need a decompressor here, ensure the default one is
  // initialized.
  if (setter.src.codec != NANOARROW_IPC_COMPRESSION_TYPE_NONE) {
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderInitDecompressor(private_data));
    setter.factory.decompressor = &private_data->decompressor;
  }

  // The flatbuffers FieldNode doesn't count the root struct so we have to loop over the
  // children ourselves
  if (field_i == -1) {
    root->array_view->length = ns(RecordBatch_length(batch));
    root->array_view->null_count = 0;
    setter.field_i++;
    setter.buffer_i++;

    for (int64_t i = 0; i < root->array_view->n_children; i++) {
      NANOARROW_RETURN_NOT_OK(
          ArrowIpcDecoderWalkSetArrayView(decoder, &setter, root->array_view->children[i],
                                          root->array->children[i], error));
    }
  } else {
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderWalkSetArrayView(
        decoder, &setter, root->array_view, root->array, error));
  }

  // If we decoded a compressed message, wait for any pending decompression tasks to
  // complete. The default compressor already performed the decompression
  if (setter.factory.decompressor != NULL) {
    NANOARROW_RETURN_NOT_OK(setter.factory.decompressor->decompress_wait(
        setter.factory.decompressor, -1, error));
  }

  *out_view = root->array_view;
  return NANOARROW_OK;
}

NANOARROW_DLL ArrowErrorCode ArrowIpcDecoderDecodeArrayViewWithDictionaries(
    struct ArrowIpcDecoder* decoder, struct ArrowBufferView body, int64_t i,
    struct ArrowIpcDictionaries* dictionaries, struct ArrowArrayView** out,
    struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;
  if (private_data->last_message == NULL ||
      decoder->message_type != NANOARROW_IPC_MESSAGE_TYPE_RECORD_BATCH) {
    ArrowErrorSet(error, "decoder did not just decode a RecordBatch message");
    return EINVAL;
  }

  return ArrowIpcDecoderDecodeArrayViewInternal(
      decoder, ArrowIpcBufferFactoryFromView(&body), i, dictionaries, out, error);
}

ArrowErrorCode ArrowIpcDecoderDecodeArrayView(struct ArrowIpcDecoder* decoder,
                                              struct ArrowBufferView body, int64_t i,
                                              struct ArrowArrayView** out,
                                              struct ArrowError* error) {
  return ArrowIpcDecoderDecodeArrayViewWithDictionaries(decoder, body, i, NULL, out,
                                                        error);
}

NANOARROW_DLL ArrowErrorCode ArrowIpcDecoderDecodeArrayWithDictionaries(
    struct ArrowIpcDecoder* decoder, struct ArrowBufferView body, int64_t i,
    struct ArrowIpcDictionaries* dictionaries, struct ArrowArray* out,
    enum ArrowValidationLevel validation_level, struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;
  if (private_data->last_message == NULL ||
      decoder->message_type != NANOARROW_IPC_MESSAGE_TYPE_RECORD_BATCH) {
    ArrowErrorSet(error, "decoder did not just decode a RecordBatch message");
    return EINVAL;
  }

  struct ArrowArrayView* array_view;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderDecodeArrayViewInternal(
      decoder, ArrowIpcBufferFactoryFromView(&body), i, dictionaries, &array_view,
      error));

  NANOARROW_RETURN_NOT_OK(ArrowArrayViewValidate(array_view, validation_level, error));

  struct ArrowArray temp;
  temp.release = NULL;
  int result =
      ArrowIpcDecoderDecodeArrayInternal(decoder, i, &temp, validation_level, error);
  if (result != NANOARROW_OK && temp.release != NULL) {
    ArrowArrayRelease(&temp);
  } else if (result != NANOARROW_OK) {
    return result;
  }

  ArrowArrayMove(&temp, out);
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderDecodeArray(struct ArrowIpcDecoder* decoder,
                                          struct ArrowBufferView body, int64_t i,
                                          struct ArrowArray* out,
                                          enum ArrowValidationLevel validation_level,
                                          struct ArrowError* error) {
  return ArrowIpcDecoderDecodeArrayWithDictionaries(decoder, body, i, NULL, out,
                                                    validation_level, error);
}

ArrowErrorCode ArrowIpcDecoderDecodeArrayFromSharedWithDictionaries(
    struct ArrowIpcDecoder* decoder, struct ArrowBuffer* body, int64_t i,
    struct ArrowIpcDictionaries* dictionaries, struct ArrowArray* out,
    enum ArrowValidationLevel validation_level, struct ArrowError* error) {
  struct ArrowArrayView* array_view;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderDecodeArrayViewInternal(
      decoder, ArrowIpcBufferFactoryFromShared(body), i, dictionaries, &array_view,
      error));

  NANOARROW_RETURN_NOT_OK(ArrowArrayViewValidate(array_view, validation_level, error));

  struct ArrowArray temp;
  temp.release = NULL;
  int result =
      ArrowIpcDecoderDecodeArrayInternal(decoder, i, &temp, validation_level, error);
  if (result != NANOARROW_OK && temp.release != NULL) {
    ArrowArrayRelease(&temp);
  } else if (result != NANOARROW_OK) {
    return result;
  }

  ArrowArrayMove(&temp, out);
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcDecoderDecodeArrayFromShared(
    struct ArrowIpcDecoder* decoder, struct ArrowBuffer* body, int64_t i,
    struct ArrowArray* out, enum ArrowValidationLevel validation_level,
    struct ArrowError* error) {
  return ArrowIpcDecoderDecodeArrayFromSharedWithDictionaries(decoder, body, i, NULL, out,
                                                              validation_level, error);
}

// The release callback of a decompressor borrowed from another decoder: the
// owner releases it.
static void ArrowIpcDecompressorReleaseBorrowed(struct ArrowIpcDecompressor* decompressor) {
  decompressor->release = NULL;
}

static ArrowErrorCode ArrowIpcDecoderDecodeDictionaryInternal(
    struct ArrowIpcDecoder* decoder, struct ArrowIpcBufferFactory factory,
    enum ArrowValidationLevel validation_level, struct ArrowIpcDictionaries* dictionaries,
    struct ArrowError* error) {
  struct ArrowIpcDecoderPrivate* private_data =
      (struct ArrowIpcDecoderPrivate*)decoder->private_data;

  if (decoder->message_type != NANOARROW_IPC_MESSAGE_TYPE_DICTIONARY_BATCH) {
    ArrowErrorSet(error, "decoder did not just decode a DictionaryBatch message");
    return EINVAL;
  }

  struct ArrowIpcDictionary* dictionary =
      ArrowIpcDictionariesFindById(dictionaries, decoder->dictionary->id);
  if (dictionary == NULL) {
    ArrowErrorSet(error,
                  "Can't decode DictionaryBatch with ID %" PRId64
                  " (dictionary definition not found)",
                  decoder->dictionary->id);
    return EINVAL;
  }

  // Set the dictionary->decoder's last message type and last message so that we can
  // decode the value.
  ns(DictionaryBatch_table_t) dictionary_batch =
      (ns(DictionaryBatch_table_t))private_data->last_message;
  ns(RecordBatch_table_t) record_batch = ns(DictionaryBatch_data(dictionary_batch));

  struct ArrowIpcDecoderPrivate* dictionary_decoder_private_data =
      (struct ArrowIpcDecoderPrivate*)dictionary->decoder.private_data;
  dictionary->decoder.message_type = NANOARROW_IPC_MESSAGE_TYPE_RECORD_BATCH;
  dictionary_decoder_private_data->last_message = record_batch;

  // Check the dictionary's field nodes and buffers against its schema, as a
  // record batch's are, before the walk indexes them.
  if (record_batch == NULL) {
    ArrowErrorSet(error, "DictionaryBatch has no data");
    return EINVAL;
  }
  dictionary->decoder.metadata_version = decoder->metadata_version;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderDecodeRecordBatchHeader(
      &dictionary->decoder, (flatbuffers_generic_t)record_batch, error));

  // A DictionaryBatch's data is a RecordBatch and may be compressed like one:
  // give the dictionary's decoder its codec and a borrowed reference to this
  // decoder's decompressor, which it would otherwise never see.
  dictionary->decoder.codec = NANOARROW_IPC_COMPRESSION_TYPE_NONE;
  if (ns(RecordBatch_compression_is_present(record_batch))) {
    ns(BodyCompression_table_t) compression = ns(RecordBatch_compression(record_batch));
    switch (ns(BodyCompression_codec(compression))) {
      case ns(CompressionType_LZ4_FRAME):
        dictionary->decoder.codec = NANOARROW_IPC_COMPRESSION_TYPE_LZ4_FRAME;
        break;
      case ns(CompressionType_ZSTD):
        dictionary->decoder.codec = NANOARROW_IPC_COMPRESSION_TYPE_ZSTD;
        break;
      default:
        ArrowErrorSet(error, "Unrecognized DictionaryBatch BodyCompression codec value: %d",
                      (int)ns(BodyCompression_codec(compression)));
        return EINVAL;
    }
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderInitDecompressor(private_data));
    if (dictionary_decoder_private_data->decompressor.release != NULL &&
        dictionary_decoder_private_data->decompressor.release !=
            &ArrowIpcDecompressorReleaseBorrowed) {
      dictionary_decoder_private_data->decompressor.release(
          &dictionary_decoder_private_data->decompressor);
    }
    dictionary_decoder_private_data->decompressor = private_data->decompressor;
    dictionary_decoder_private_data->decompressor.release =
        &ArrowIpcDecompressorReleaseBorrowed;
  }
  // Transfer the endianness setting so that buffers are byte-swapped if needed
  dictionary_decoder_private_data->endianness = private_data->endianness;

  struct ArrowArrayView* array_view;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderDecodeArrayViewInternal(
      &dictionary->decoder, factory, 0, dictionaries, &array_view, error));

  NANOARROW_RETURN_NOT_OK(ArrowArrayViewValidate(array_view, validation_level, error));

  struct ArrowArray tmp;
  tmp.release = NULL;
  int result = ArrowIpcDecoderDecodeArrayInternal(&dictionary->decoder, 0, &tmp,
                                                  validation_level, error);
  if (result != NANOARROW_OK && tmp.release != NULL) {
    ArrowArrayRelease(&tmp);
    return result;
  } else if (result != NANOARROW_OK) {
    return result;
  }

  if (decoder->dictionary->is_delta) {
    result = ArrowIpcDictionaryAppend(dictionary, &tmp, error);
  } else {
    result = ArrowIpcDictionaryReplace(dictionary, &tmp, error);
  }

  if (result != NANOARROW_OK) {
    ArrowArrayRelease(&tmp);
    return result;
  }

  return NANOARROW_OK;
}

NANOARROW_DLL ArrowErrorCode ArrowIpcDecoderDecodeDictionary(
    struct ArrowIpcDecoder* decoder, struct ArrowBufferView body,
    enum ArrowValidationLevel validation_level, struct ArrowIpcDictionaries* dictionaries,
    struct ArrowError* error) {
  NANOARROW_DCHECK(decoder != NULL);
  NANOARROW_DCHECK(dictionaries != NULL);

  return ArrowIpcDecoderDecodeDictionaryInternal(decoder,
                                                 ArrowIpcBufferFactoryFromView(&body),
                                                 validation_level, dictionaries, error);
}

NANOARROW_DLL ArrowErrorCode ArrowIpcDecoderDecodeDictionaryFromShared(
    struct ArrowIpcDecoder* decoder, struct ArrowBuffer* shared,
    enum ArrowValidationLevel validation_level, struct ArrowIpcDictionaries* dictionaries,
    struct ArrowError* error) {
  NANOARROW_DCHECK(decoder != NULL);
  NANOARROW_DCHECK(shared != NULL);
  NANOARROW_DCHECK(dictionaries != NULL);

  return ArrowIpcDecoderDecodeDictionaryInternal(decoder,
                                                 ArrowIpcBufferFactoryFromShared(shared),
                                                 validation_level, dictionaries, error);
}
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "flatcc/flatcc_builder.h"
#include "nanoarrow.h"
#include "nanoarrow_ipc.h"

#define ns(x) FLATBUFFERS_WRAP_NAMESPACE(org_apache_arrow_flatbuf, x)

#define FLATCC_RETURN_UNLESS_0_NO_NS(x, error)                        \
  if ((x) != 0) {                                                     \
    ArrowErrorSet(error, "%s:%d: %s failed", __FILE__, __LINE__, #x); \
    return ENOMEM;                                                    \
  }

#define FLATCC_RETURN_UNLESS_0(x, error) FLATCC_RETURN_UNLESS_0_NO_NS(ns(x), error)

#define FLATCC_RETURN_IF_NULL(x, error)                                 \
  if (!(x)) {                                                           \
    ArrowErrorSet(error, "%s:%d: %s was null", __FILE__, __LINE__, #x); \
    return ENOMEM;                                                      \
  }

struct ArrowIpcEncoderPrivate {
  flatcc_builder_t builder;
  struct ArrowBuffer buffers;
  struct ArrowBuffer nodes;
  int encoding_footer;
  struct ArrowIpcDictionaryEncodings dictionary_encodings;
};

ArrowErrorCode ArrowIpcEncoderInit(struct ArrowIpcEncoder* encoder) {
  NANOARROW_DCHECK(encoder != NULL);
  memset(encoder, 0, sizeof(struct ArrowIpcEncoder));
  encoder->private_data = ArrowMalloc(sizeof(struct ArrowIpcEncoderPrivate));
  struct ArrowIpcEncoderPrivate* private =
      (struct ArrowIpcEncoderPrivate*)encoder->private_data;
  if (private == NULL) {
    return ENOMEM;
  }
  if (flatcc_builder_init(&private->builder) == -1) {
    ArrowFree(private);
    return ESPIPE;
  }
  private->encoding_footer = 0;
  ArrowBufferInit(&private->buffers);
  ArrowBufferInit(&private->nodes);
  ArrowIpcDictionaryEncodingsInit(&private->dictionary_encodings);
  return NANOARROW_OK;
}

void ArrowIpcEncoderReset(struct ArrowIpcEncoder* encoder) {
  NANOARROW_DCHECK(encoder != NULL);
  struct ArrowIpcEncoderPrivate* private =
      (struct ArrowIpcEncoderPrivate*)encoder->private_data;
  if (private != NULL) {
    flatcc_builder_clear(&private->builder);
    ArrowBufferReset(&private->nodes);
    ArrowBufferReset(&private->buffers);
    ArrowIpcDictionaryEncodingsReset(&private->dictionary_encodings);
    ArrowFree(private);
  }
  memset(encoder, 0, sizeof(struct ArrowIpcEncoder));
}

static ArrowErrorCode ArrowIpcEncoderWriteContinuationAndSize(struct ArrowBuffer* out,
                                                              size_t size) {
  _NANOARROW_CHECK_UPPER_LIMIT(size, INT32_MAX);
  NANOARROW_RETURN_NOT_OK(ArrowBufferAppendInt32(out, -1));

  if (ArrowIpcSystemEndianness() == NANOARROW_IPC_ENDIANNESS_BIG) {
    return ArrowBufferAppendInt32(out, (int32_t)bswap32((uint32_t)size));
  } else {
    return ArrowBufferAppendInt32(out, (int32_t)size);
  }
}

ArrowErrorCode ArrowIpcEncoderFinalizeBuffer(struct ArrowIpcEncoder* encoder,
                                             char encapsulate, struct ArrowBuffer* out) {
  NANOARROW_DCHECK(encoder != NULL && encoder->private_data != NULL && out != NULL);
  struct ArrowIpcEncoderPrivate* private =
      (struct ArrowIpcEncoderPrivate*)encoder->private_data;

  size_t size = flatcc_builder_get_buffer_size(&private->builder);

  if (encapsulate) {
    int64_t padded_size = _ArrowRoundUpToMultipleOf8(size);
    NANOARROW_RETURN_NOT_OK(
        ArrowBufferReserve(out, sizeof(int32_t) + sizeof(int32_t) + padded_size));
    NANOARROW_ASSERT_OK(ArrowIpcEncoderWriteContinuationAndSize(out, padded_size));
  } else {
    NANOARROW_RETURN_NOT_OK(ArrowBufferReserve(out, size));
  }

  if (size == 0) {
    // Finalizing an empty flatcc_builder_t triggers an assertion
    return NANOARROW_OK;
  }

  void* data =
      flatcc_builder_copy_buffer(&private->builder, out->data + out->size_bytes, size);
  NANOARROW_DCHECK(data != NULL);
  NANOARROW_UNUSED(data);
  out->size_bytes += size;

  while (encapsulate && out->size_bytes % 8 != 0) {
    // zero padding bytes, if any
    out->data[out->size_bytes++] = 0;
  }

  // don't deallocate yet, just wipe the builder's current Message
  flatcc_builder_reset(&private->builder);
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcEncodeFieldType(flatcc_builder_t* builder,
                                              const struct ArrowSchemaView* schema_view,
                                              struct ArrowError* error) {
  switch (schema_view->type) {
    case NANOARROW_TYPE_NA:
      FLATCC_RETURN_UNLESS_0(Field_type_Null_create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_BOOL:
      FLATCC_RETURN_UNLESS_0(Field_type_Bool_create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_UINT8:
    case NANOARROW_TYPE_INT8:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Int_create(builder, 8, schema_view->type == NANOARROW_TYPE_INT8),
          error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_UINT16:
    case NANOARROW_TYPE_INT16:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Int_create(builder, 16, schema_view->type == NANOARROW_TYPE_INT16),
          error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_UINT32:
    case NANOARROW_TYPE_INT32:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Int_create(builder, 32, schema_view->type == NANOARROW_TYPE_INT32),
          error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_UINT64:
    case NANOARROW_TYPE_INT64:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Int_create(builder, 64, schema_view->type == NANOARROW_TYPE_INT64),
          error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_HALF_FLOAT:
      FLATCC_RETURN_UNLESS_0(Field_type_FloatingPoint_create(builder, ns(Precision_HALF)),
                             error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_FLOAT:
      FLATCC_RETURN_UNLESS_0(
          Field_type_FloatingPoint_create(builder, ns(Precision_SINGLE)), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_DOUBLE:
      FLATCC_RETURN_UNLESS_0(
          Field_type_FloatingPoint_create(builder, ns(Precision_DOUBLE)), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_DECIMAL32:
    case NANOARROW_TYPE_DECIMAL64:
    case NANOARROW_TYPE_DECIMAL128:
    case NANOARROW_TYPE_DECIMAL256:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Decimal_create(builder, schema_view->decimal_precision,
                                    schema_view->decimal_scale,
                                    schema_view->decimal_bitwidth),
          error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_STRING:
      FLATCC_RETURN_UNLESS_0(Field_type_Utf8_create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_LARGE_STRING:
      FLATCC_RETURN_UNLESS_0(Field_type_LargeUtf8_create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_BINARY:
      FLATCC_RETURN_UNLESS_0(Field_type_Binary_create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_LARGE_BINARY:
      FLATCC_RETURN_UNLESS_0(Field_type_LargeBinary_create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_DATE32:
      FLATCC_RETURN_UNLESS_0(Field_type_Date_create(builder, ns(DateUnit_DAY)), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_DATE64:
      FLATCC_RETURN_UNLESS_0(Field_type_Date_create(builder, ns(DateUnit_MILLISECOND)),
                             error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_INTERVAL_MONTHS:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Interval_create(builder, ns(IntervalUnit_YEAR_MONTH)), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_INTERVAL_DAY_TIME:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Interval_create(builder, ns(IntervalUnit_DAY_TIME)), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_INTERVAL_MONTH_DAY_NANO:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Interval_create(builder, ns(IntervalUnit_MONTH_DAY_NANO)), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_TIMESTAMP:
      FLATCC_RETURN_UNLESS_0(Field_type_Timestamp_start(builder), error);
      FLATCC_RETURN_UNLESS_0(
          Timestamp_unit_add(builder, (ns(TimeUnit_enum_t))schema_view->time_unit),
          error);
      if (schema_view->timezone && schema_view->timezone[0] != 0) {
        FLATCC_RETURN_UNLESS_0(
            Timestamp_timezone_create_str(builder, schema_view->timezone), error);
      }
      FLATCC_RETURN_UNLESS_0(Field_type_Timestamp_end(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_TIME32:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Time_create(builder, (ns(TimeUnit_enum_t))schema_view->time_unit,
                                 32),
          error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_TIME64:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Time_create(builder, (ns(TimeUnit_enum_t))schema_view->time_unit,
                                 64),
          error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_DURATION:
      FLATCC_RETURN_UNLESS_0(Field_type_Duration_create(
                                 builder, (ns(TimeUnit_enum_t))schema_view->time_unit),
                             error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_FIXED_SIZE_BINARY:
      FLATCC_RETURN_UNLESS_0(
          Field_type_FixedSizeBinary_create(builder, schema_view->fixed_size), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_LIST:
      FLATCC_RETURN_UNLESS_0(Field_type_List_create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_LARGE_LIST:
      FLATCC_RETURN_UNLESS_0(Field_type_LargeList_create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_FIXED_SIZE_LIST:
      FLATCC_RETURN_UNLESS_0(
          Field_type_FixedSizeList_create(builder, schema_view->fixed_size), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_RUN_END_ENCODED:
      FLATCC_RETURN_UNLESS_0(Field_type_RunEndEncoded_create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_STRUCT:
      FLATCC_RETURN_UNLESS_0(Field_type_Struct__create(builder), error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_SPARSE_UNION:
    case NANOARROW_TYPE_DENSE_UNION: {
      FLATCC_RETURN_UNLESS_0(Field_type_Union_start(builder), error);

      FLATCC_RETURN_UNLESS_0(
          Union_mode_add(builder, schema_view->type == NANOARROW_TYPE_DENSE_UNION),
          error);
      if (schema_view->union_type_ids) {
        int8_t type_ids[128];
        int n = _ArrowParseUnionTypeIds(schema_view->union_type_ids, type_ids);
        if (n != 0) {
          FLATCC_RETURN_UNLESS_0(Union_typeIds_start(builder), error);
          int32_t* type_ids_32 = (int32_t*)ns(Union_typeIds_extend(builder, n));
          FLATCC_RETURN_IF_NULL(type_ids_32, error);

          for (int i = 0; i < n; i++) {
            type_ids_32[i] = type_ids[i];
          }
          FLATCC_RETURN_UNLESS_0(Union_typeIds_end(builder), error);
        }
      }

      FLATCC_RETURN_UNLESS_0(Field_type_Union_end(builder), error);
      return NANOARROW_OK;
    }

    case NANOARROW_TYPE_MAP:
      FLATCC_RETURN_UNLESS_0(
          Field_type_Map_create(builder,
                                schema_view->schema->flags & ARROW_FLAG_MAP_KEYS_SORTED),
          error);
      return NANOARROW_OK;

    case NANOARROW_TYPE_DICTIONARY:
      ArrowErrorSet(error, "IPC encoding of dictionary types unsupported");
      return ENOTSUP;

    default:
      ArrowErrorSet(error, "Expected a valid enum ArrowType value but found %d",
                    schema_view->type);
      return EINVAL;
  }
}

static ArrowErrorCode ArrowIpcEncodeField(
    flatcc_builder_t* builder, const struct ArrowSchema* schema,
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    struct ArrowError* error);

static ArrowErrorCode ArrowIpcEncodeMetadata(flatcc_builder_t* builder,
                                             const struct ArrowSchema* schema,
                                             int (*push_start)(flatcc_builder_t*),
                                             ns(KeyValue_ref_t) *
                                                 (*push_end)(flatcc_builder_t*),
                                             struct ArrowError* error) {
  struct ArrowMetadataReader metadata;
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowMetadataReaderInit(&metadata, schema->metadata),
                                     error);
  while (metadata.remaining_keys > 0) {
    struct ArrowStringView key, value;
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowMetadataReaderRead(&metadata, &key, &value),
                                       error);
    FLATCC_RETURN_UNLESS_0_NO_NS(push_start(builder), error);
    FLATCC_RETURN_UNLESS_0(KeyValue_key_create_strn(builder, key.data, key.size_bytes),
                           error);
    FLATCC_RETURN_UNLESS_0(
        KeyValue_value_create_strn(builder, value.data, value.size_bytes), error);
    FLATCC_RETURN_IF_NULL(push_end(builder), error);
  }
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcEncodeFields(
    flatcc_builder_t* builder, const struct ArrowSchema* schema,
    int (*push_start)(flatcc_builder_t*),
    ns(Field_ref_t) * (*push_end)(flatcc_builder_t*),
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    struct ArrowError* error) {
  for (int i = 0; i < schema->n_children; i++) {
    FLATCC_RETURN_UNLESS_0_NO_NS(push_start(builder), error);
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcEncodeField(builder, schema->children[i], dictionary_encodings, error));
    FLATCC_RETURN_IF_NULL(push_end(builder), error);
  }
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcEncodeField(
    flatcc_builder_t* builder, const struct ArrowSchema* schema,
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    struct ArrowError* error) {
  FLATCC_RETURN_UNLESS_0(Field_name_create_str(builder, schema->name), error);
  FLATCC_RETURN_UNLESS_0(
      Field_nullable_add(builder, (schema->flags & ARROW_FLAG_NULLABLE) != 0), error);

  struct ArrowSchemaView schema_view;
  NANOARROW_RETURN_NOT_OK(ArrowSchemaViewInit(&schema_view, schema, error));

  if (schema_view.type == NANOARROW_TYPE_DICTIONARY) {
    const struct ArrowIpcDictionaryEncoding* encoding =
        ArrowIpcDictionaryEncodingsFind(dictionary_encodings, schema);

    // We just computed these dictionary ids, so we should be able to resolve them
    if (encoding == NULL) {
      ArrowErrorSet(error, "Unexpected missing dictionary encoding for field");
      return EINVAL;
    }

    // Determine the index type's bitWidth and is_signed from the storage_type
    int32_t index_bitwidth;
    flatbuffers_bool_t index_is_signed;
    switch (schema_view.storage_type) {
      case NANOARROW_TYPE_INT8:
        index_bitwidth = 8;
        index_is_signed = 1;
        break;
      case NANOARROW_TYPE_UINT8:
        index_bitwidth = 8;
        index_is_signed = 0;
        break;
      case NANOARROW_TYPE_INT16:
        index_bitwidth = 16;
        index_is_signed = 1;
        break;
      case NANOARROW_TYPE_UINT16:
        index_bitwidth = 16;
        index_is_signed = 0;
        break;
      case NANOARROW_TYPE_INT32:
        index_bitwidth = 32;
        index_is_signed = 1;
        break;
      case NANOARROW_TYPE_UINT32:
        index_bitwidth = 32;
        index_is_signed = 0;
        break;
      case NANOARROW_TYPE_INT64:
        index_bitwidth = 64;
        index_is_signed = 1;
        break;
      case NANOARROW_TYPE_UINT64:
        index_bitwidth = 64;
        index_is_signed = 0;
        break;
      default:
        ArrowErrorSet(error, "Invalid dictionary index type: %s",
                      ArrowTypeString(schema_view.storage_type));
        return EINVAL;
    }

    // Create the Int type for the index type
    ns(Int_ref_t) index_type_ref =
        ns(Int_create(builder, index_bitwidth, index_is_signed));
    FLATCC_RETURN_IF_NULL(index_type_ref, error);

    // Create the DictionaryEncoding with id, indexType, isOrdered, and dictionaryKind
    flatbuffers_bool_t is_ordered = (schema->flags & ARROW_FLAG_DICTIONARY_ORDERED) != 0;
    ns(DictionaryEncoding_ref_t) dict_encoding_ref =
        ns(DictionaryEncoding_create(builder, encoding->id, index_type_ref, is_ordered,
                                     ns(DictionaryKind_DenseArray)));
    FLATCC_RETURN_IF_NULL(dict_encoding_ref, error);

    // Add the dictionary encoding to the field
    FLATCC_RETURN_UNLESS_0(Field_dictionary_add(builder, dict_encoding_ref), error);

    NANOARROW_RETURN_NOT_OK(ArrowSchemaViewInit(&schema_view, schema->dictionary, error));
  }

  NANOARROW_RETURN_NOT_OK(ArrowIpcEncodeFieldType(builder, &schema_view, error));

  if (schema->n_children != 0) {
    FLATCC_RETURN_UNLESS_0(Field_children_start(builder), error);
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcEncodeFields(builder, schema, &ns(Field_children_push_start),
                             &ns(Field_children_push_end), dictionary_encodings, error));
    FLATCC_RETURN_UNLESS_0(Field_children_end(builder), error);
  }

  if (schema->metadata) {
    FLATCC_RETURN_UNLESS_0(Field_custom_metadata_start(builder), error);
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcEncodeMetadata(builder, schema, &ns(Field_custom_metadata_push_start),
                               &ns(Field_custom_metadata_push_end), error));
    FLATCC_RETURN_UNLESS_0(Field_custom_metadata_end(builder), error);
  }
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcEncodeSchema(
    flatcc_builder_t* builder, const struct ArrowSchema* schema,
    const struct ArrowIpcDictionaryEncodings* dictionary_encodings,
    struct ArrowError* error) {
  NANOARROW_DCHECK(schema->release != NULL);

  if (strcmp(schema->format, "+s") != 0) {
    ArrowErrorSet(
        error,
        "Cannot encode schema with format '%s'; top level schema must have struct type",
        schema->format);
    return EINVAL;
  }

  if (ArrowIpcSystemEndianness() == NANOARROW_IPC_ENDIANNESS_LITTLE) {
    FLATCC_RETURN_UNLESS_0(Schema_endianness_add(builder, ns(Endianness_Little)), error);
  } else {
    FLATCC_RETURN_UNLESS_0(Schema_endianness_add(builder, ns(Endianness_Big)), error);
  }

  FLATCC_RETURN_UNLESS_0(Schema_fields_start(builder), error);
  NANOARROW_RETURN_NOT_OK(
      ArrowIpcEncodeFields(builder, schema, &ns(Schema_fields_push_start),
                           &ns(Schema_fields_push_end), dictionary_encodings, error));
  FLATCC_RETURN_UNLESS_0(Schema_fields_end(builder), error);

  FLATCC_RETURN_UNLESS_0(Schema_custom_metadata_start(builder), error);
  if (schema->metadata) {
    NANOARROW_RETURN_NOT_OK(
        ArrowIpcEncodeMetadata(builder, schema, &ns(Schema_custom_metadata_push_start),
                               &ns(Schema_custom_metadata_push_end), error));
  }
  FLATCC_RETURN_UNLESS_0(Schema_custom_metadata_end(builder), error);

  FLATCC_RETURN_UNLESS_0(Schema_features_start(builder), error);
  FLATCC_RETURN_UNLESS_0(Schema_features_end(builder), error);

  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcEncoderEncodeSchema(struct ArrowIpcEncoder* encoder,
                                           const struct ArrowSchema* schema,
                                           struct ArrowError* error) {
  NANOARROW_DCHECK(encoder != NULL && encoder->private_data != NULL && schema != NULL);

  struct ArrowIpcEncoderPrivate* private =
      (struct ArrowIpcEncoderPrivate*)encoder->private_data;

  flatcc_builder_t* builder = &private->builder;

  FLATCC_RETURN_UNLESS_0(Message_start_as_root(builder), error);

  FLATCC_RETURN_UNLESS_0(Message_version_add(builder, ns(MetadataVersion_V5)), error);

  FLATCC_RETURN_UNLESS_0(Message_header_Schema_start(builder), error);

  // Look for any fields of the schema that should be dictionary encoded
  if (private->dictionary_encodings.encodings.size_bytes > 0) {
    ArrowIpcDictionaryEncodingsReset(&private->dictionary_encodings);
    ArrowIpcDictionaryEncodingsInit(&private->dictionary_encodings);
  }
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowIpcDictionaryEncodingsAppendSchema(&private->dictionary_encodings, schema),
      error);

  NANOARROW_RETURN_NOT_OK(
      ArrowIpcEncodeSchema(builder, schema, &private->dictionary_encodings, error));

  FLATCC_RETURN_UNLESS_0(Message_header_Schema_end(builder), error);

  FLATCC_RETURN_UNLESS_0(Message_bodyLength_add(builder, 0), error);

  FLATCC_RETURN_IF_NULL(ns(Message_end_as_root(builder)), error);
  return NANOARROW_OK;
}

struct ArrowIpcBufferEncoder {
  /// \brief Callback invoked against each buffer to be encoded
  ///
  /// Encoding of buffers is left as a callback to accommodate dissociated data storage.
  /// One implementation of this callback might copy all buffers into a contiguous body
  /// for use in an arrow IPC stream, another implementation might store offsets and
  /// lengths relative to a known arena.
  ArrowErrorCode (*encode_buffer)(struct ArrowBufferView buffer_view,
                                  struct ArrowIpcEncoder* encoder,
                                  struct ArrowIpcBufferEncoder* buffer_encoder,
                                  int64_t* offset, int64_t* length,
                                  struct ArrowError* error);

  /// \brief Pointer to arbitrary data used by encode_buffer()
  void* encode_buffer_state;

  /// \brief Finalized body length of the most recently encoded RecordBatch message
  ///
  /// encode_buffer() is expected to update this while encoding each buffer. After all
  /// buffers are encoded, this will be written to the RecordBatch's .bodyLength
  int64_t body_length;
};

static ArrowErrorCode ArrowIpcEncoderBuildContiguousBodyBufferCallback(
    struct ArrowBufferView buffer_view, struct ArrowIpcEncoder* encoder,
    struct ArrowIpcBufferEncoder* buffer_encoder, int64_t* offset, int64_t* length,
    struct ArrowError* error) {
  NANOARROW_UNUSED(encoder);

  struct ArrowBuffer* body_buffer =
      (struct ArrowBuffer*)buffer_encoder->encode_buffer_state;

  int64_t old_size = body_buffer->size_bytes;
  int64_t buffer_begin = _ArrowRoundUpToMultipleOf8(old_size);
  int64_t buffer_end = buffer_begin + buffer_view.size_bytes;
  int64_t new_size = _ArrowRoundUpToMultipleOf8(buffer_end);

  // reserve all the memory we'll need now
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferReserve(body_buffer, new_size - old_size),
                                     error);

  // zero padding up to the start of the buffer
  NANOARROW_ASSERT_OK(ArrowBufferAppendFill(body_buffer, 0, buffer_begin - old_size));

  // store offset and length of the buffer
  *offset = buffer_begin;
  *length = buffer_view.size_bytes;

  NANOARROW_ASSERT_OK(
      ArrowBufferAppend(body_buffer, buffer_view.data.data, buffer_view.size_bytes));

  // zero padding after writing the buffer
  NANOARROW_DCHECK(body_buffer->size_bytes == buffer_end);
  NANOARROW_ASSERT_OK(ArrowBufferAppendFill(body_buffer, 0, new_size - buffer_end));

  buffer_encoder->body_length = body_buffer->size_bytes;
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcEncoderEncodeRecordBatchImpl(
    struct ArrowIpcEncoder* encoder, struct ArrowIpcBufferEncoder* buffer_encoder,
    const struct ArrowArrayView* array_view, struct ArrowBuffer* buffers,
    struct ArrowBuffer* nodes, struct ArrowError* error) {
  if (array_view->offset != 0) {
    ArrowErrorSet(error, "Cannot encode arrays with nonzero offset");
    return ENOTSUP;
  }

  // A dictionary-encoded column's indices are this batch's buffers; its values
  // are written as a DictionaryBatch of their own.
  for (int64_t c = 0; c < array_view->n_children; ++c) {
    const struct ArrowArrayView* child = array_view->children[c];

    struct ns(FieldNode) node = {child->length, child->null_count};
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferAppend(nodes, &node, sizeof(node)),
                                       error);

    for (int64_t b = 0; b < child->array->n_buffers; ++b) {
      struct ns(Buffer) buffer;
      NANOARROW_RETURN_NOT_OK(
          buffer_encoder->encode_buffer(child->buffer_views[b], encoder, buffer_encoder,
                                        &buffer.offset, &buffer.length, error));
      NANOARROW_RETURN_NOT_OK_WITH_ERROR(
          ArrowBufferAppend(buffers, &buffer, sizeof(buffer)), error);
    }

    NANOARROW_RETURN_NOT_OK(ArrowIpcEncoderEncodeRecordBatchImpl(
        encoder, buffer_encoder, child, buffers, nodes, error));
  }
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcEncoderEncodeRecordBatch(
    struct ArrowIpcEncoder* encoder, struct ArrowIpcBufferEncoder* buffer_encoder,
    const struct ArrowArrayView* array_view, struct ArrowError* error) {
  NANOARROW_DCHECK(encoder != NULL && encoder->private_data != NULL &&
                   buffer_encoder != NULL && buffer_encoder->encode_buffer != NULL);
  if (array_view->null_count != 0 && ArrowArrayViewComputeNullCount(array_view) != 0) {
    ArrowErrorSet(error,
                  "RecordBatches cannot be constructed from arrays with top level nulls");
    return EINVAL;
  }

  if (array_view->storage_type != NANOARROW_TYPE_STRUCT) {
    ArrowErrorSet(
        error,
        "RecordBatches cannot be constructed from arrays of type other than struct");
    return EINVAL;
  }

  struct ArrowIpcEncoderPrivate* private =
      (struct ArrowIpcEncoderPrivate*)encoder->private_data;

  flatcc_builder_t* builder = &private->builder;

  FLATCC_RETURN_UNLESS_0(Message_start_as_root(builder), error);
  FLATCC_RETURN_UNLESS_0(Message_version_add(builder, ns(MetadataVersion_V5)), error);

  FLATCC_RETURN_UNLESS_0(Message_header_RecordBatch_start(builder), error);
  FLATCC_RETURN_UNLESS_0(RecordBatch_length_add(builder, array_view->length), error);

  NANOARROW_ASSERT_OK(ArrowBufferResize(&private->buffers, 0, 0));
  NANOARROW_ASSERT_OK(ArrowBufferResize(&private->nodes, 0, 0));
  NANOARROW_RETURN_NOT_OK(ArrowIpcEncoderEncodeRecordBatchImpl(
      encoder, buffer_encoder, array_view, &private->buffers, &private->nodes, error));

  FLATCC_RETURN_UNLESS_0(RecordBatch_nodes_create(  //
                             builder, (struct ns(FieldNode)*)private->nodes.data,
                             private->nodes.size_bytes / sizeof(struct ns(FieldNode))),
                         error);
  FLATCC_RETURN_UNLESS_0(RecordBatch_buffers_create(  //
                             builder, (struct ns(Buffer)*)private->buffers.data,
                             private->buffers.size_bytes / sizeof(struct ns(Buffer))),
                         error);

  FLATCC_RETURN_UNLESS_0(Message_header_RecordBatch_end(builder), error);

  FLATCC_RETURN_UNLESS_0(Message_bodyLength_add(builder, buffer_encoder->body_length),
                         error);
  FLATCC_RETURN_IF_NULL(ns(Message_end_as_root(builder)), error);
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcEncoderEncodeSimpleRecordBatch(
    struct ArrowIpcEncoder* encoder, const struct ArrowArrayView* array_view,
    struct ArrowBuffer* body_buffer, struct ArrowError* error) {
  NANOARROW_DCHECK(encoder != NULL && encoder->private_data != NULL &&
                   body_buffer != NULL);

  struct ArrowIpcBufferEncoder buffer_encoder = {
      .encode_buffer = &ArrowIpcEncoderBuildContiguousBodyBufferCallback,
      .encode_buffer_state = body_buffer,
      .body_length = 0,
  };

  return ArrowIpcEncoderEncodeRecordBatch(encoder, &buffer_encoder, array_view, error);
}

struct ArrowIpcEncoderCallbackState {
  ArrowIpcEncodeBufferFunction encode_buffer;
  void* state;
};

static ArrowErrorCode ArrowIpcEncoderCallbackTrampoline(
    struct ArrowBufferView buffer_view, struct ArrowIpcEncoder* encoder,
    struct ArrowIpcBufferEncoder* buffer_encoder, int64_t* offset, int64_t* length,
    struct ArrowError* error) {
  NANOARROW_UNUSED(encoder);
  struct ArrowIpcEncoderCallbackState* callback =
      (struct ArrowIpcEncoderCallbackState*)buffer_encoder->encode_buffer_state;
  return callback->encode_buffer(buffer_view, callback->state, offset, length,
                                 &buffer_encoder->body_length, error);
}

ArrowErrorCode ArrowIpcEncoderEncodeBatch(struct ArrowIpcEncoder* encoder,
                                          const struct ArrowArrayView* array_view,
                                          ArrowIpcEncodeBufferFunction encode_buffer,
                                          void* state,
                                          enum ArrowIpcCompressionType codec,
                                          int64_t dictionary_id, char is_delta,
                                          struct ArrowError* error) {
  NANOARROW_DCHECK(encoder != NULL && encoder->private_data != NULL);
  if (array_view->null_count != 0 && ArrowArrayViewComputeNullCount(array_view) != 0) {
    ArrowErrorSet(error,
                  "RecordBatches cannot be constructed from arrays with top level nulls");
    return EINVAL;
  }
  if (array_view->storage_type != NANOARROW_TYPE_STRUCT) {
    ArrowErrorSet(
        error,
        "RecordBatches cannot be constructed from arrays of type other than struct");
    return EINVAL;
  }

  struct ArrowIpcEncoderCallbackState callback = {encode_buffer, state};
  struct ArrowIpcBufferEncoder buffer_encoder = {
      .encode_buffer = &ArrowIpcEncoderCallbackTrampoline,
      .encode_buffer_state = &callback,
      .body_length = 0,
  };

  struct ArrowIpcEncoderPrivate* private =
      (struct ArrowIpcEncoderPrivate*)encoder->private_data;
  flatcc_builder_t* builder = &private->builder;

  FLATCC_RETURN_UNLESS_0(Message_start_as_root(builder), error);
  FLATCC_RETURN_UNLESS_0(Message_version_add(builder, ns(MetadataVersion_V5)), error);
  if (dictionary_id >= 0) {
    FLATCC_RETURN_UNLESS_0(Message_header_DictionaryBatch_start(builder), error);
    FLATCC_RETURN_UNLESS_0(DictionaryBatch_id_add(builder, dictionary_id), error);
    FLATCC_RETURN_UNLESS_0(DictionaryBatch_data_start(builder), error);
  } else {
    FLATCC_RETURN_UNLESS_0(Message_header_RecordBatch_start(builder), error);
  }
  FLATCC_RETURN_UNLESS_0(RecordBatch_length_add(builder, array_view->length), error);
  if (codec != NANOARROW_IPC_COMPRESSION_TYPE_NONE) {
    FLATCC_RETURN_UNLESS_0(RecordBatch_compression_start(builder), error);
    FLATCC_RETURN_UNLESS_0(
        BodyCompression_codec_add(builder, codec == NANOARROW_IPC_COMPRESSION_TYPE_ZSTD
                                               ? ns(CompressionType_ZSTD)
                                               : ns(CompressionType_LZ4_FRAME)),
        error);
    FLATCC_RETURN_UNLESS_0(RecordBatch_compression_end(builder), error);
  }

  NANOARROW_ASSERT_OK(ArrowBufferResize(&private->buffers, 0, 0));
  NANOARROW_ASSERT_OK(ArrowBufferResize(&private->nodes, 0, 0));
  NANOARROW_RETURN_NOT_OK(ArrowIpcEncoderEncodeRecordBatchImpl(
      encoder, &buffer_encoder, array_view, &private->buffers, &private->nodes, error));
  FLATCC_RETURN_UNLESS_0(RecordBatch_nodes_create(  //
                             builder, (struct ns(FieldNode)*)private->nodes.data,
                             private->nodes.size_bytes / sizeof(struct ns(FieldNode))),
                         error);
  FLATCC_RETURN_UNLESS_0(RecordBatch_buffers_create(  //
                             builder, (struct ns(Buffer)*)private->buffers.data,
                             private->buffers.size_bytes / sizeof(struct ns(Buffer))),
                         error);

  if (dictionary_id >= 0) {
    FLATCC_RETURN_UNLESS_0(DictionaryBatch_data_end(builder), error);
    FLATCC_RETURN_UNLESS_0(DictionaryBatch_isDelta_add(builder, is_delta != 0), error);
    FLATCC_RETURN_UNLESS_0(Message_header_DictionaryBatch_end(builder), error);
  } else {
    FLATCC_RETURN_UNLESS_0(Message_header_RecordBatch_end(builder), error);
  }
  FLATCC_RETURN_UNLESS_0(Message_bodyLength_add(builder, buffer_encoder.body_length),
                         error);
  FLATCC_RETURN_IF_NULL(ns(Message_end_as_root(builder)), error);
  return NANOARROW_OK;
}

void ArrowIpcFooterInit(struct ArrowIpcFooter* footer) {
  footer->schema.release = NULL;
  ArrowBufferInit(&footer->record_batch_blocks);
  ArrowBufferInit(&footer->dictionary_blocks);
  ArrowIpcDictionaryEncodingsInit(&footer->dictionaries);
}

void ArrowIpcFooterReset(struct ArrowIpcFooter* footer) {
  if (footer->schema.release != NULL) {
    ArrowSchemaRelease(&footer->schema);
  }
  ArrowBufferReset(&footer->record_batch_blocks);
  ArrowBufferReset(&footer->dictionary_blocks);
  ArrowIpcDictionaryEncodingsReset(&footer->dictionaries);
}

ArrowErrorCode ArrowIpcEncoderEncodeFooter(struct ArrowIpcEncoder* encoder,
                                           const struct ArrowIpcFooter* footer,
                                           struct ArrowError* error) {
  NANOARROW_DCHECK(encoder != NULL && encoder->private_data != NULL && footer != NULL);

  struct ArrowIpcEncoderPrivate* private =
      (struct ArrowIpcEncoderPrivate*)encoder->private_data;

  flatcc_builder_t* builder = &private->builder;

  FLATCC_RETURN_UNLESS_0(Footer_start_as_root(builder), error);

  FLATCC_RETURN_UNLESS_0(Footer_version_add(builder, ns(MetadataVersion_V5)), error);

  FLATCC_RETURN_UNLESS_0(Footer_schema_start(builder), error);
  NANOARROW_RETURN_NOT_OK(
      ArrowIpcEncodeSchema(builder, &footer->schema, &footer->dictionaries, error));
  FLATCC_RETURN_UNLESS_0(Footer_schema_end(builder), error);

  const struct ArrowIpcFileBlock* blocks =
      (struct ArrowIpcFileBlock*)footer->record_batch_blocks.data;
  int64_t n_blocks =
      footer->record_batch_blocks.size_bytes / sizeof(struct ArrowIpcFileBlock);

  FLATCC_RETURN_UNLESS_0(Footer_recordBatches_start(builder), error);
  struct ns(Block)* flatcc_RecordBatch_blocks =
      ns(Footer_recordBatches_extend(builder, n_blocks));
  FLATCC_RETURN_IF_NULL(flatcc_RecordBatch_blocks, error);
  for (int64_t i = 0; i < n_blocks; i++) {
    // Block has padding after metaDataLength: zero it, or the file carries
    // whatever the stack held and is not reproducible.
    memset(&flatcc_RecordBatch_blocks[i], 0, sizeof(struct ns(Block)));
    flatcc_RecordBatch_blocks[i].offset = blocks[i].offset;
    flatcc_RecordBatch_blocks[i].metaDataLength = blocks[i].metadata_length;
    flatcc_RecordBatch_blocks[i].bodyLength = blocks[i].body_length;
  }
  FLATCC_RETURN_UNLESS_0(Footer_recordBatches_end(builder), error);

  // The footer's DictionaryBatch blocks, so a reader can find the dictionaries.
  const struct ArrowIpcFileBlock* dictionary_blocks =
      (struct ArrowIpcFileBlock*)footer->dictionary_blocks.data;
  int64_t n_dictionary_blocks =
      footer->dictionary_blocks.size_bytes / sizeof(struct ArrowIpcFileBlock);
  if (n_dictionary_blocks > 0) {
    FLATCC_RETURN_UNLESS_0(Footer_dictionaries_start(builder), error);
    struct ns(Block)* flatcc_dictionary_blocks =
        ns(Footer_dictionaries_extend(builder, n_dictionary_blocks));
    FLATCC_RETURN_IF_NULL(flatcc_dictionary_blocks, error);
    for (int64_t i = 0; i < n_dictionary_blocks; i++) {
      memset(&flatcc_dictionary_blocks[i], 0, sizeof(struct ns(Block)));
      flatcc_dictionary_blocks[i].offset = dictionary_blocks[i].offset;
      flatcc_dictionary_blocks[i].metaDataLength = dictionary_blocks[i].metadata_length;
      flatcc_dictionary_blocks[i].bodyLength = dictionary_blocks[i].body_length;
    }
    FLATCC_RETURN_UNLESS_0(Footer_dictionaries_end(builder), error);
  }

  FLATCC_RETURN_IF_NULL(ns(Footer_end_as_root(builder)), error);
  return NANOARROW_OK;
}
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include "nanoarrow.h"
#include "nanoarrow_ipc.h"

// ENODATA is an XSI extension and is not defined by all libcs (e.g., older
// Windows/MinGW toolchains used by R 3.6, FreeBSD, and OpenBSD).
#if !defined(ENODATA)
#define ENODATA 120
#endif

// Sentinel value to indicate that we haven't read a message yet
// and don't know the number of header prefix bytes to expect.
static const int32_t kExpectedHeaderPrefixSizeNotSet = -1;

void ArrowIpcInputStreamMove(struct ArrowIpcInputStream* src,
                             struct ArrowIpcInputStream* dst) {
  memcpy(dst, src, sizeof(struct ArrowIpcInputStream));
  src->release = NULL;
}

struct ArrowIpcInputStreamBufferPrivate {
  struct ArrowBuffer input;
  int64_t cursor_bytes;
};

static ArrowErrorCode ArrowIpcInputStreamBufferRead(struct ArrowIpcInputStream* stream,
                                                    uint8_t* buf, int64_t buf_size_bytes,
                                                    int64_t* size_read_out,
                                                    struct ArrowError* error) {
  NANOARROW_UNUSED(error);

  if (buf_size_bytes == 0) {
    *size_read_out = 0;
    return NANOARROW_OK;
  }

  struct ArrowIpcInputStreamBufferPrivate* private_data =
      (struct ArrowIpcInputStreamBufferPrivate*)stream->private_data;
  int64_t bytes_remaining = private_data->input.size_bytes - private_data->cursor_bytes;
  int64_t bytes_to_read;
  if (bytes_remaining > buf_size_bytes) {
    bytes_to_read = buf_size_bytes;
  } else {
    bytes_to_read = bytes_remaining;
  }

  if (bytes_to_read > 0) {
    memcpy(buf, private_data->input.data + private_data->cursor_bytes, bytes_to_read);
  }

  *size_read_out = bytes_to_read;
  private_data->cursor_bytes += bytes_to_read;
  return NANOARROW_OK;
}

static void ArrowIpcInputStreamBufferRelease(struct ArrowIpcInputStream* stream) {
  struct ArrowIpcInputStreamBufferPrivate* private_data =
      (struct ArrowIpcInputStreamBufferPrivate*)stream->private_data;
  ArrowBufferReset(&private_data->input);
  ArrowFree(private_data);
  stream->release = NULL;
}

ArrowErrorCode ArrowIpcInputStreamInitBuffer(struct ArrowIpcInputStream* stream,
                                             struct ArrowBuffer* input) {
  NANOARROW_DCHECK(stream != NULL);

  struct ArrowIpcInputStreamBufferPrivate* private_data =
      (struct ArrowIpcInputStreamBufferPrivate*)ArrowMalloc(
          sizeof(struct ArrowIpcInputStreamBufferPrivate));
  if (private_data == NULL) {
    return ENOMEM;
  }

  ArrowBufferMove(input, &private_data->input);
  private_data->cursor_bytes = 0;
  stream->read = &ArrowIpcInputStreamBufferRead;
  stream->release = &ArrowIpcInputStreamBufferRelease;
  stream->private_data = private_data;

  return NANOARROW_OK;
}

struct ArrowIpcInputStreamFilePrivate {
  FILE* file_ptr;
  int stream_finished;
  int close_on_release;
};

static void ArrowIpcInputStreamFileRelease(struct ArrowIpcInputStream* stream) {
  struct ArrowIpcInputStreamFilePrivate* private_data =
      (struct ArrowIpcInputStreamFilePrivate*)stream->private_data;

  if (private_data->file_ptr != NULL && private_data->close_on_release) {
    fclose(private_data->file_ptr);
  }

  ArrowFree(private_data);
  stream->release = NULL;
}

static ArrowErrorCode ArrowIpcInputStreamFileRead(struct ArrowIpcInputStream* stream,
                                                  uint8_t* buf, int64_t buf_size_bytes,
                                                  int64_t* size_read_out,
                                                  struct ArrowError* error) {
  struct ArrowIpcInputStreamFilePrivate* private_data =
      (struct ArrowIpcInputStreamFilePrivate*)stream->private_data;

  if (private_data->stream_finished) {
    *size_read_out = 0;
    return NANOARROW_OK;
  }

  // Do the read
  int64_t bytes_read = (int64_t)fread(buf, 1, buf_size_bytes, private_data->file_ptr);
  *size_read_out = bytes_read;

  if (bytes_read != buf_size_bytes) {
    private_data->stream_finished = 1;

    // Inspect error
    int has_error = !feof(private_data->file_ptr) && ferror(private_data->file_ptr);

    // Try to close the file now
    if (private_data->close_on_release) {
      if (fclose(private_data->file_ptr) == 0) {
        private_data->file_ptr = NULL;
      }
    }

    // Maybe return error
    if (has_error) {
      ArrowErrorSet(error, "ArrowIpcInputStreamFile IO error");
      return EIO;
    }
  }

  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcInputStreamInitFile(struct ArrowIpcInputStream* stream,
                                           void* file_ptr, int close_on_release) {
  NANOARROW_DCHECK(stream != NULL);
  if (file_ptr == NULL) {
    return errno ? errno : EINVAL;
  }

  struct ArrowIpcInputStreamFilePrivate* private_data =
      (struct ArrowIpcInputStreamFilePrivate*)ArrowMalloc(
          sizeof(struct ArrowIpcInputStreamFilePrivate));
  if (private_data == NULL) {
    return ENOMEM;
  }

  private_data->file_ptr = (FILE*)file_ptr;
  private_data->close_on_release = close_on_release;
  private_data->stream_finished = 0;

  stream->read = &ArrowIpcInputStreamFileRead;
  stream->release = &ArrowIpcInputStreamFileRelease;
  stream->private_data = private_data;
  return NANOARROW_OK;
}

struct ArrowIpcArrayStreamReaderPrivate {
  struct ArrowIpcInputStream input;
  struct ArrowIpcDecoder decoder;
  int use_shared_buffers;
  struct ArrowSchema out_schema;
  int64_t field_index;
  struct ArrowBuffer header;
  struct ArrowBuffer body;
  int32_t expected_header_prefix_size;
  struct ArrowIpcDictionaries dictionaries;
  struct ArrowError error;
};

static void ArrowIpcArrayStreamReaderRelease(struct ArrowArrayStream* stream) {
  struct ArrowIpcArrayStreamReaderPrivate* private_data =
      (struct ArrowIpcArrayStreamReaderPrivate*)stream->private_data;

  if (private_data->input.release != NULL) {
    private_data->input.release(&private_data->input);
  }

  ArrowIpcDecoderReset(&private_data->decoder);

  if (private_data->out_schema.release != NULL) {
    ArrowSchemaRelease(&private_data->out_schema);
  }

  ArrowBufferReset(&private_data->header);
  ArrowBufferReset(&private_data->body);

  if (private_data->dictionaries.private_data != NULL) {
    ArrowIpcDictionariesReset(&private_data->dictionaries);
  }

  ArrowFree(private_data);
  stream->release = NULL;
}

static int ArrowIpcArrayStreamReaderNextHeader(
    struct ArrowIpcArrayStreamReaderPrivate* private_data, int schema_expected) {
  private_data->header.size_bytes = 0;
  int64_t bytes_read = 0;

  // Read 8 bytes (continuation + header size in bytes)
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferReserve(&private_data->header, 8),
                                     &private_data->error);
  NANOARROW_RETURN_NOT_OK(private_data->input.read(&private_data->input,
                                                   private_data->header.data, 8,
                                                   &bytes_read, &private_data->error));
  private_data->header.size_bytes += bytes_read;

  if (bytes_read == 0) {
    // The caller might not use this error message (e.g., if the end of the stream
    // is one of the valid outcomes) but we set the error anyway in case it gets
    // propagated higher (e.g., if the stream is empty and there's no schema message)
    ArrowErrorSet(&private_data->error, "No data available on stream");
    return ENODATA;
  } else if (bytes_read == 4 && private_data->expected_header_prefix_size == 4) {
    // Special case very, very old IPC streams that used 0x00000000 as the
    // end-of-stream indicator. We may want to remove this case at some point:
    // https://github.com/apache/arrow-nanoarrow/issues/648
    uint32_t last_four_bytes = 0;
    memcpy(&last_four_bytes, private_data->header.data, sizeof(uint32_t));
    if (last_four_bytes == 0) {
      ArrowErrorSet(&private_data->error, "No data available on stream");
      return ENODATA;
    } else {
      ArrowErrorSet(&private_data->error,
                    "Expected 0x00000000 if exactly four bytes are available at the end "
                    "of a stream");
      return EINVAL;
    }
  } else if (bytes_read != 8) {
    ArrowErrorSet(&private_data->error,
                  "Expected at least 8 bytes in remainder of stream");
    return EINVAL;
  }

  struct ArrowBufferView input_view;
  input_view.data.data = private_data->header.data;
  input_view.size_bytes = private_data->header.size_bytes;

  // Use PeekHeader to fill in decoder.header_size_bytes
  int32_t prefix_size_bytes = 0;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderPeekHeader(
      &private_data->decoder, input_view, &prefix_size_bytes, &private_data->error));

  // Check for a consistent header prefix size
  if (private_data->expected_header_prefix_size != kExpectedHeaderPrefixSizeNotSet &&
      prefix_size_bytes != private_data->expected_header_prefix_size) {
    ArrowErrorSet(&private_data->error,
                  "Expected prefix %d prefix header bytes but found %d",
                  (int)private_data->expected_header_prefix_size, (int)prefix_size_bytes);
    return EINVAL;
  } else {
    private_data->expected_header_prefix_size = prefix_size_bytes;
  }

  // Legacy streams are missing the 0xFFFFFFFF at the start of the message. The
  // decoder can handle this; however, verification will fail because flatbuffers
  // must be 8-byte aligned. To handle this case, we prepend the continuation
  // token to the start of the stream and ensure that we read four fewer bytes
  // the next time we issue a read. We may be able to remove this case in the future:
  // https://github.com/apache/arrow-nanoarrow/issues/648
  int64_t extra_bytes_already_read = 0;
  if (prefix_size_bytes == 4) {
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowBufferReserve(&private_data->header, 4),
                                       &private_data->error);
    memmove(private_data->header.data + 4, private_data->header.data,
            private_data->header.size_bytes);
    uint32_t continuation = 0xFFFFFFFFU;
    memcpy(private_data->header.data, &continuation, sizeof(uint32_t));
    private_data->header.size_bytes += 4;
    extra_bytes_already_read = 4;

    input_view.data.data = private_data->header.data;
    input_view.size_bytes = private_data->header.size_bytes;

    int32_t new_prefix_size_bytes;
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderPeekHeader(&private_data->decoder, input_view,
                                                      &new_prefix_size_bytes,
                                                      &private_data->error));
    NANOARROW_DCHECK(new_prefix_size_bytes == 8);
  }

  // Read the header bytes
  int64_t expected_header_bytes = private_data->decoder.header_size_bytes - 8;
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowBufferReserve(&private_data->header,
                         expected_header_bytes - extra_bytes_already_read),
      &private_data->error);
  NANOARROW_RETURN_NOT_OK(private_data->input.read(
      &private_data->input, private_data->header.data + private_data->header.size_bytes,
      expected_header_bytes - extra_bytes_already_read, &bytes_read,
      &private_data->error));
  private_data->header.size_bytes += bytes_read;

  // Verify + decode the header
  input_view.data.data = private_data->header.data;
  input_view.size_bytes = private_data->header.size_bytes;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderVerifyHeader(&private_data->decoder, input_view,
                                                      &private_data->error));

  // If we have a 4-byte header prefix, make sure the metadata version is V4
  // (Note that some V4 IPC files have an 8 byte header prefix).
  if (prefix_size_bytes == 4 &&
      private_data->decoder.metadata_version != NANOARROW_IPC_METADATA_VERSION_V4) {
    ArrowErrorSet(&private_data->error,
                  "Header prefix size of four bytes is only allowed for V4 metadata");
    return EINVAL;
  }

  // Don't decode the message if it's of the wrong type (because the error message
  // is better communicated by the caller)
  if ((schema_expected &&
       private_data->decoder.message_type != NANOARROW_IPC_MESSAGE_TYPE_SCHEMA) ||
      (!schema_expected &&
       private_data->decoder.message_type == NANOARROW_IPC_MESSAGE_TYPE_SCHEMA)) {
    return NANOARROW_OK;
  }

  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderDecodeHeader(&private_data->decoder, input_view,
                                                      &private_data->error));
  return NANOARROW_OK;
}

static int ArrowIpcArrayStreamReaderNextBody(
    struct ArrowIpcArrayStreamReaderPrivate* private_data) {
  int64_t bytes_read;
  int64_t bytes_to_read = private_data->decoder.body_size_bytes;

  // Read the body bytes
  private_data->body.size_bytes = 0;
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowBufferReserve(&private_data->body, bytes_to_read), &private_data->error);
  NANOARROW_RETURN_NOT_OK(private_data->input.read(&private_data->input,
                                                   private_data->body.data, bytes_to_read,
                                                   &bytes_read, &private_data->error));
  private_data->body.size_bytes += bytes_read;

  if (bytes_read != bytes_to_read) {
    ArrowErrorSet(&private_data->error,
                  "Expected to be able to read %" PRId64
                  " bytes for message body but got %" PRId64,
                  bytes_to_read, bytes_read);
    return ESPIPE;
  } else {
    return NANOARROW_OK;
  }
}

static int ArrowIpcArrayStreamReaderReadSchemaIfNeeded(
    struct ArrowIpcArrayStreamReaderPrivate* private_data) {
  if (private_data->out_schema.release != NULL) {
    return NANOARROW_OK;
  }

  NANOARROW_RETURN_NOT_OK(ArrowIpcArrayStreamReaderNextHeader(private_data, 1));

  // Error if this isn't a schema message
  if (private_data->decoder.message_type != NANOARROW_IPC_MESSAGE_TYPE_SCHEMA) {
    ArrowErrorSet(&private_data->error,
                  "Unexpected message type at start of input (expected Schema)");
    return EINVAL;
  }

  // ...or if it uses features we don't support
  if (private_data->decoder.feature_flags & NANOARROW_IPC_FEATURE_COMPRESSED_BODY) {
    ArrowErrorSet(&private_data->error,
                  "This stream uses unsupported feature COMPRESSED_BODY");
    return EINVAL;
  }

  if (private_data->decoder.feature_flags &
      NANOARROW_IPC_FEATURE_DICTIONARY_REPLACEMENT) {
    ArrowErrorSet(&private_data->error,
                  "This stream uses unsupported feature DICTIONARY_REPLACEMENT");
    return EINVAL;
  }

  // Notify the decoder of buffer endianness
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowIpcDecoderSetEndianness(&private_data->decoder,
                                   private_data->decoder.endianness),
      &private_data->error);

  struct ArrowSchema tmp;
  struct ArrowIpcDictionaryEncodings dictionary_encodings;
  NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderDecodeSchemaWithDictionaries(
      &private_data->decoder, &tmp, &dictionary_encodings, &private_data->error));

  // Only support "read the whole thing" for now
  if (private_data->field_index != -1) {
    ArrowSchemaRelease(&tmp);
    ArrowIpcDictionaryEncodingsReset(&dictionary_encodings);
    ArrowErrorSet(&private_data->error, "Field index != -1 is not yet supported");
    return ENOTSUP;
  }

  // Initialize dictionary decoders
  int result = ArrowIpcDictionariesInit(&private_data->dictionaries,
                                        &dictionary_encodings, &private_data->error);
  if (result != NANOARROW_OK) {
    ArrowIpcDictionaryEncodingsReset(&dictionary_encodings);
    ArrowSchemaRelease(&tmp);
    return result;
  }

  // Notify the decoder of the schema for forthcoming messages
  result = ArrowIpcDecoderSetSchemaWithDictionaries(
      &private_data->decoder, &tmp, &dictionary_encodings, &private_data->error);
  ArrowIpcDictionaryEncodingsReset(&dictionary_encodings);
  if (result != NANOARROW_OK) {
    ArrowIpcDictionariesReset(&private_data->dictionaries);
    ArrowSchemaRelease(&tmp);
    return result;
  }

  ArrowSchemaMove(&tmp, &private_data->out_schema);
  return NANOARROW_OK;
}

static int ArrowIpcArrayStreamReaderGetSchema(struct ArrowArrayStream* stream,
                                              struct ArrowSchema* out) {
  struct ArrowIpcArrayStreamReaderPrivate* private_data =
      (struct ArrowIpcArrayStreamReaderPrivate*)stream->private_data;
  private_data->error.message[0] = '\0';
  NANOARROW_RETURN_NOT_OK(ArrowIpcArrayStreamReaderReadSchemaIfNeeded(private_data));
  return ArrowSchemaDeepCopy(&private_data->out_schema, out);
}

static int ArrowIpcArrayStreamReaderProcessRecordBatch(
    struct ArrowIpcArrayStreamReaderPrivate* private_data, struct ArrowArray* out) {
  // Read in the body
  NANOARROW_RETURN_NOT_OK(ArrowIpcArrayStreamReaderNextBody(private_data));

  if (private_data->use_shared_buffers) {
    struct ArrowBuffer shared;
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(
        ArrowSharedBufferInit(&shared, &private_data->body), &private_data->error);
    ArrowErrorCode result = ArrowIpcDecoderDecodeArrayFromSharedWithDictionaries(
        &private_data->decoder, &shared, private_data->field_index,
        &private_data->dictionaries, out, NANOARROW_VALIDATION_LEVEL_FULL,
        &private_data->error);
    ArrowBufferReset(&shared);
    NANOARROW_RETURN_NOT_OK(result);
  } else {
    struct ArrowBufferView body_view;
    body_view.data.data = private_data->body.data;
    body_view.size_bytes = private_data->body.size_bytes;

    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderDecodeArrayWithDictionaries(
        &private_data->decoder, body_view, private_data->field_index,
        &private_data->dictionaries, out, NANOARROW_VALIDATION_LEVEL_FULL,
        &private_data->error));
  }

  return NANOARROW_OK;
}

static int ArrowIpcArrayStreamReaderProcessDictionary(
    struct ArrowIpcArrayStreamReaderPrivate* private_data) {
  // Read in the body
  NANOARROW_RETURN_NOT_OK(ArrowIpcArrayStreamReaderNextBody(private_data));

  if (private_data->use_shared_buffers) {
    // Decode the dictionary
    struct ArrowBuffer shared;
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(
        ArrowSharedBufferInit(&shared, &private_data->body), &private_data->error);
    int result = ArrowIpcDecoderDecodeDictionaryFromShared(
        &private_data->decoder, &shared, NANOARROW_VALIDATION_LEVEL_FULL,
        &private_data->dictionaries, &private_data->error);
    ArrowBufferReset(&shared);
    NANOARROW_RETURN_NOT_OK(result);
  } else {
    struct ArrowBufferView body_view;
    body_view.data.data = private_data->body.data;
    body_view.size_bytes = private_data->body.size_bytes;
    NANOARROW_RETURN_NOT_OK(ArrowIpcDecoderDecodeDictionary(
        &private_data->decoder, body_view, NANOARROW_VALIDATION_LEVEL_FULL,
        &private_data->dictionaries, &private_data->error));
  }

  return NANOARROW_OK;
}

static int ArrowIpcArrayStreamReaderProcessMessage(
    struct ArrowIpcArrayStreamReaderPrivate* private_data,
    enum ArrowIpcMessageType* message_type, struct ArrowArray* out) {
  // Read + decode the next header
  int result = ArrowIpcArrayStreamReaderNextHeader(private_data, 0);
  if (result == ENODATA) {
    // Stream is finished either because there is no input or because
    // end of stream bytes were read. Read this as a RecordBatch in the
    // sense that we populate out->release to NULL and return OK.
    *message_type = NANOARROW_IPC_MESSAGE_TYPE_RECORD_BATCH;
    out->release = NULL;
    return NANOARROW_OK;
  } else if (result != NANOARROW_OK) {
    // Other error
    return result;
  }

  // Make sure we have a RecordBatch message or DictionaryBatch message
  switch (private_data->decoder.message_type) {
    case NANOARROW_IPC_MESSAGE_TYPE_RECORD_BATCH:
      *message_type = NANOARROW_IPC_MESSAGE_TYPE_RECORD_BATCH;
      return ArrowIpcArrayStreamReaderProcessRecordBatch(private_data, out);
    case NANOARROW_IPC_MESSAGE_TYPE_DICTIONARY_BATCH:
      *message_type = NANOARROW_IPC_MESSAGE_TYPE_DICTIONARY_BATCH;
      return ArrowIpcArrayStreamReaderProcessDictionary(private_data);
    default:
      ArrowErrorSet(&private_data->error,
                    "Unexpected message type (expected RecordBatch or DictionaryBatch)");
      return EINVAL;
  }
}

static int ArrowIpcArrayStreamReaderGetNext(struct ArrowArrayStream* stream,
                                            struct ArrowArray* out) {
  struct ArrowIpcArrayStreamReaderPrivate* private_data =
      (struct ArrowIpcArrayStreamReaderPrivate*)stream->private_data;
  ArrowErrorInit(&private_data->error);
  NANOARROW_RETURN_NOT_OK(ArrowIpcArrayStreamReaderReadSchemaIfNeeded(private_data));

  enum ArrowIpcMessageType message_type;
  struct ArrowArray tmp;
  tmp.release = NULL;

  do {
    int result =
        ArrowIpcArrayStreamReaderProcessMessage(private_data, &message_type, &tmp);
    if (result != NANOARROW_OK) {
      if (tmp.release != NULL) {
        ArrowArrayRelease(&tmp);
      }

      return result;
    }
  } while (message_type != NANOARROW_IPC_MESSAGE_TYPE_RECORD_BATCH);

  ArrowArrayMove(&tmp, out);
  return NANOARROW_OK;
}

static const char* ArrowIpcArrayStreamReaderGetLastError(
    struct ArrowArrayStream* stream) {
  struct ArrowIpcArrayStreamReaderPrivate* private_data =
      (struct ArrowIpcArrayStreamReaderPrivate*)stream->private_data;
  return private_data->error.message;
}

ArrowErrorCode ArrowIpcArrayStreamReaderInit(
    struct ArrowArrayStream* out, struct ArrowIpcInputStream* input_stream,
    struct ArrowIpcArrayStreamReaderOptions* options) {
  struct ArrowIpcArrayStreamReaderPrivate* private_data =
      (struct ArrowIpcArrayStreamReaderPrivate*)ArrowMalloc(
          sizeof(struct ArrowIpcArrayStreamReaderPrivate));
  if (private_data == NULL) {
    return ENOMEM;
  }

  int result = ArrowIpcDecoderInit(&private_data->decoder);
  if (result != NANOARROW_OK) {
    ArrowFree(private_data);
    return result;
  }

  ArrowBufferInit(&private_data->header);
  ArrowBufferInit(&private_data->body);
  private_data->out_schema.release = NULL;
  ArrowIpcInputStreamMove(input_stream, &private_data->input);
  private_data->expected_header_prefix_size = kExpectedHeaderPrefixSizeNotSet;
  private_data->dictionaries.private_data = NULL;

  if (options != NULL) {
    private_data->field_index = options->field_index;
    private_data->use_shared_buffers = options->use_shared_buffers;
  } else {
    private_data->field_index = -1;
    private_data->use_shared_buffers = ArrowSharedBufferIsThreadSafe();
  }

  out->private_data = private_data;
  out->get_schema = &ArrowIpcArrayStreamReaderGetSchema;
  out->get_next = &ArrowIpcArrayStreamReaderGetNext;
  out->get_last_error = &ArrowIpcArrayStreamReaderGetLastError;
  out->release = &ArrowIpcArrayStreamReaderRelease;

  return NANOARROW_OK;
}
// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "flatcc/flatcc_builder.h"
#include "nanoarrow.h"
#include "nanoarrow_ipc.h"

#define ns(x) FLATBUFFERS_WRAP_NAMESPACE(org_apache_arrow_flatbuf, x)

void ArrowIpcOutputStreamMove(struct ArrowIpcOutputStream* src,
                              struct ArrowIpcOutputStream* dst) {
  NANOARROW_DCHECK(src != NULL && dst != NULL);

  memcpy(dst, src, sizeof(struct ArrowIpcOutputStream));
  src->release = NULL;
}

ArrowErrorCode ArrowIpcOutputStreamWrite(struct ArrowIpcOutputStream* stream,
                                         struct ArrowBufferView data,
                                         struct ArrowError* error) {
  while (data.size_bytes != 0) {
    int64_t bytes_written = 0;
    NANOARROW_RETURN_NOT_OK(stream->write(stream, data.data.as_uint8, data.size_bytes,
                                          &bytes_written, error));
    data.size_bytes -= bytes_written;
    data.data.as_uint8 += bytes_written;
  }
  return NANOARROW_OK;
}

struct ArrowIpcOutputStreamBufferPrivate {
  struct ArrowBuffer* output;
};

static ArrowErrorCode ArrowIpcOutputStreamBufferWrite(struct ArrowIpcOutputStream* stream,
                                                      const void* buf,
                                                      int64_t buf_size_bytes,
                                                      int64_t* size_written_out,
                                                      struct ArrowError* error) {
  struct ArrowIpcOutputStreamBufferPrivate* private_data =
      (struct ArrowIpcOutputStreamBufferPrivate*)stream->private_data;
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowBufferAppend(private_data->output, buf, buf_size_bytes), error);
  *size_written_out = buf_size_bytes;
  return NANOARROW_OK;
}

static void ArrowIpcOutputStreamBufferRelease(struct ArrowIpcOutputStream* stream) {
  struct ArrowIpcOutputStreamBufferPrivate* private_data =
      (struct ArrowIpcOutputStreamBufferPrivate*)stream->private_data;
  ArrowFree(private_data);
  stream->release = NULL;
}

ArrowErrorCode ArrowIpcOutputStreamInitBuffer(struct ArrowIpcOutputStream* stream,
                                              struct ArrowBuffer* output) {
  NANOARROW_DCHECK(stream != NULL && output != NULL);

  struct ArrowIpcOutputStreamBufferPrivate* private_data =
      (struct ArrowIpcOutputStreamBufferPrivate*)ArrowMalloc(
          sizeof(struct ArrowIpcOutputStreamBufferPrivate));
  if (private_data == NULL) {
    return ENOMEM;
  }

  private_data->output = output;
  stream->write = &ArrowIpcOutputStreamBufferWrite;
  stream->release = &ArrowIpcOutputStreamBufferRelease;
  stream->private_data = private_data;

  return NANOARROW_OK;
}

struct ArrowIpcOutputStreamFilePrivate {
  FILE* file_ptr;
  int stream_finished;
  int close_on_release;
};

static void ArrowIpcOutputStreamFileRelease(struct ArrowIpcOutputStream* stream) {
  struct ArrowIpcOutputStreamFilePrivate* private_data =
      (struct ArrowIpcOutputStreamFilePrivate*)stream->private_data;

  if (private_data->file_ptr != NULL && private_data->close_on_release) {
    fclose(private_data->file_ptr);
  }

  ArrowFree(private_data);
  stream->release = NULL;
}

static ArrowErrorCode ArrowIpcOutputStreamFileWrite(struct ArrowIpcOutputStream* stream,
                                                    const void* buf,
                                                    int64_t buf_size_bytes,
                                                    int64_t* size_written_out,
                                                    struct ArrowError* error) {
  struct ArrowIpcOutputStreamFilePrivate* private_data =
      (struct ArrowIpcOutputStreamFilePrivate*)stream->private_data;

  if (private_data->stream_finished) {
    *size_written_out = 0;
    return NANOARROW_OK;
  }

  // Do the write
  int64_t bytes_written = (int64_t)fwrite(buf, 1, buf_size_bytes, private_data->file_ptr);
  *size_written_out = bytes_written;

  if (bytes_written != buf_size_bytes) {
    private_data->stream_finished = 1;

    // Inspect error
    int has_error = !feof(private_data->file_ptr) && ferror(private_data->file_ptr);

    // Try to close the file now
    if (private_data->close_on_release) {
      if (fclose(private_data->file_ptr) == 0) {
        private_data->file_ptr = NULL;
      }
    }

    // Maybe return error
    if (has_error) {
      ArrowErrorSet(error, "ArrowIpcOutputStreamFile IO error");
      return EIO;
    }
  }

  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcOutputStreamInitFile(struct ArrowIpcOutputStream* stream,
                                            void* file_ptr, int close_on_release) {
  NANOARROW_DCHECK(stream != NULL);
  if (file_ptr == NULL) {
    return errno ? errno : EINVAL;
  }

  struct ArrowIpcOutputStreamFilePrivate* private_data =
      (struct ArrowIpcOutputStreamFilePrivate*)ArrowMalloc(
          sizeof(struct ArrowIpcOutputStreamFilePrivate));
  if (private_data == NULL) {
    return ENOMEM;
  }

  private_data->file_ptr = (FILE*)file_ptr;
  private_data->close_on_release = close_on_release;
  private_data->stream_finished = 0;

  stream->write = &ArrowIpcOutputStreamFileWrite;
  stream->release = &ArrowIpcOutputStreamFileRelease;
  stream->private_data = private_data;
  return NANOARROW_OK;
}

struct ArrowIpcWriterPrivate {
  struct ArrowIpcEncoder encoder;
  struct ArrowIpcOutputStream output_stream;
  struct ArrowBuffer buffer;
  struct ArrowBuffer body_buffer;

  int writing_file;
  int64_t bytes_written;
  struct ArrowIpcFooter footer;
};

ArrowErrorCode ArrowIpcWriterInit(struct ArrowIpcWriter* writer,
                                  struct ArrowIpcOutputStream* output_stream) {
  NANOARROW_DCHECK(writer != NULL && output_stream != NULL);

  struct ArrowIpcWriterPrivate* private =
      (struct ArrowIpcWriterPrivate*)ArrowMalloc(sizeof(struct ArrowIpcWriterPrivate));

  if (private == NULL) {
    return ENOMEM;
  }
  NANOARROW_RETURN_NOT_OK(ArrowIpcEncoderInit(&private->encoder));
  ArrowIpcOutputStreamMove(output_stream, &private->output_stream);

  ArrowBufferInit(&private->buffer);
  ArrowBufferInit(&private->body_buffer);

  private->writing_file = 0;
  private->bytes_written = 0;
  ArrowIpcFooterInit(&private->footer);

  writer->private_data = private;
  return NANOARROW_OK;
}

void ArrowIpcWriterReset(struct ArrowIpcWriter* writer) {
  NANOARROW_DCHECK(writer != NULL);

  struct ArrowIpcWriterPrivate* private =
      (struct ArrowIpcWriterPrivate*)writer->private_data;

  if (private != NULL) {
    ArrowIpcEncoderReset(&private->encoder);
    private->output_stream.release(&private->output_stream);
    ArrowBufferReset(&private->buffer);
    ArrowBufferReset(&private->body_buffer);

    ArrowIpcFooterReset(&private->footer);

    ArrowFree(private);
  }
  memset(writer, 0, sizeof(struct ArrowIpcWriter));
}

static struct ArrowBufferView ArrowBufferToBufferView(const struct ArrowBuffer* buffer) {
  struct ArrowBufferView buffer_view = {
      .data.as_uint8 = buffer->data,
      .size_bytes = buffer->size_bytes,
  };
  return buffer_view;
}

// Eventually, it may be necessary to construct an ArrowIpcWriter which doesn't rely on
// blocking writes (ArrowIpcOutputStreamWrite). For example an ArrowIpcOutputStream
// might wrap a socket which is not always able to transmit all bytes of a Message. In
// that case users of ArrowIpcWriter might prefer to do other work until a socket is
// ready rather than blocking, or timeout, or otherwise respond to partial transmission.
//
// This could be handled by:
// - keeping partially sent buffers internal and signalling incomplete transmission by
//   raising EAGAIN, returning "bytes actually written", ...
//   - when the caller is ready to try again, call ArrowIpcWriterWriteSome()
// - exposing internal buffers which have not been completely sent, deferring
//   follow-up transmission to the caller

ArrowErrorCode ArrowIpcWriterWriteSchema(struct ArrowIpcWriter* writer,
                                         const struct ArrowSchema* in,
                                         struct ArrowError* error) {
  NANOARROW_DCHECK(writer != NULL && writer->private_data != NULL && in != NULL);
  struct ArrowIpcWriterPrivate* private =
      (struct ArrowIpcWriterPrivate*)writer->private_data;

  NANOARROW_ASSERT_OK(ArrowBufferResize(&private->buffer, 0, 0));

  NANOARROW_RETURN_NOT_OK(ArrowIpcEncoderEncodeSchema(&private->encoder, in, error));
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowIpcEncoderFinalizeBuffer(&private->encoder, /*encapsulate=*/1,
                                    &private->buffer),
      error);

  if (private->writing_file) {
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(ArrowSchemaDeepCopy(in, &private->footer.schema),
                                       error);
  }
  private->bytes_written += private->buffer.size_bytes;

  return ArrowIpcOutputStreamWrite(&private->output_stream,
                                   ArrowBufferToBufferView(&private->buffer), error);
}

ArrowErrorCode ArrowIpcWriterWriteArrayView(struct ArrowIpcWriter* writer,
                                            const struct ArrowArrayView* in,
                                            struct ArrowError* error) {
  NANOARROW_DCHECK(writer != NULL && writer->private_data != NULL);
  struct ArrowIpcWriterPrivate* private =
      (struct ArrowIpcWriterPrivate*)writer->private_data;

  if (in == NULL) {
    int32_t eos[] = {-1, 0};
    private->bytes_written += sizeof(eos);
    struct ArrowBufferView eos_view = {.data.as_int32 = eos, .size_bytes = sizeof(eos)};
    return ArrowIpcOutputStreamWrite(&private->output_stream, eos_view, error);
  }

  NANOARROW_ASSERT_OK(ArrowBufferResize(&private->buffer, 0, 0));
  NANOARROW_ASSERT_OK(ArrowBufferResize(&private->body_buffer, 0, 0));

  NANOARROW_RETURN_NOT_OK(ArrowIpcEncoderEncodeSimpleRecordBatch(
      &private->encoder, in, &private->body_buffer, error));
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowIpcEncoderFinalizeBuffer(&private->encoder, /*encapsulate=*/1,
                                    &private->buffer),
      error);

  if (private->writing_file) {
    _NANOARROW_CHECK_RANGE(private->buffer.size_bytes, 0, INT32_MAX);
    struct ArrowIpcFileBlock block = {
        .offset = private->bytes_written,
        .metadata_length = (int32_t) private->buffer.size_bytes,
        .body_length = private->body_buffer.size_bytes,
    };
    NANOARROW_RETURN_NOT_OK_WITH_ERROR(
        ArrowBufferAppend(&private->footer.record_batch_blocks, &block, sizeof(block)),
        error);
  }
  private->bytes_written += private->buffer.size_bytes;
  private->bytes_written += private->body_buffer.size_bytes;

  NANOARROW_RETURN_NOT_OK(ArrowIpcOutputStreamWrite(
      &private->output_stream, ArrowBufferToBufferView(&private->buffer), error));
  NANOARROW_RETURN_NOT_OK(ArrowIpcOutputStreamWrite(
      &private->output_stream, ArrowBufferToBufferView(&private->body_buffer), error));
  return NANOARROW_OK;
}

static ArrowErrorCode ArrowIpcWriterWriteArrayStreamImpl(
    struct ArrowIpcWriter* writer, struct ArrowArrayStream* in,
    struct ArrowSchema* schema, struct ArrowArray* array,
    struct ArrowArrayView* array_view, struct ArrowError* error) {
  NANOARROW_RETURN_NOT_OK(ArrowArrayStreamGetSchema(in, schema, error));
  NANOARROW_RETURN_NOT_OK(ArrowIpcWriterWriteSchema(writer, schema, error));

  NANOARROW_RETURN_NOT_OK(ArrowArrayViewInitFromSchema(array_view, schema, error));
  while (1) {
    NANOARROW_RETURN_NOT_OK(ArrowArrayStreamGetNext(in, array, error));
    if (array->release == NULL) {
      break;
    }

    NANOARROW_RETURN_NOT_OK(ArrowArrayViewSetArray(array_view, array, error));
    NANOARROW_RETURN_NOT_OK(ArrowIpcWriterWriteArrayView(writer, array_view, error));
    ArrowArrayRelease(array);
  }

  // The stream is complete, signal the end to the caller
  return ArrowIpcWriterWriteArrayView(writer, NULL, error);
}

ArrowErrorCode ArrowIpcWriterWriteArrayStream(struct ArrowIpcWriter* writer,
                                              struct ArrowArrayStream* in,
                                              struct ArrowError* error) {
  NANOARROW_DCHECK(writer != NULL && writer->private_data != NULL && in != NULL);

  struct ArrowSchema schema = {.release = NULL};
  struct ArrowArray array = {.release = NULL};
  struct ArrowArrayView array_view;
  ArrowArrayViewInitFromType(&array_view, NANOARROW_TYPE_UNINITIALIZED);

  ArrowErrorCode result =
      ArrowIpcWriterWriteArrayStreamImpl(writer, in, &schema, &array, &array_view, error);

  if (schema.release != NULL) {
    ArrowSchemaRelease(&schema);
  }

  if (array.release != NULL) {
    ArrowArrayRelease(&array);
  }

  ArrowArrayViewReset(&array_view);

  return result;
}

#define NANOARROW_IPC_FILE_PADDED_MAGIC "ARROW1\0"

ArrowErrorCode ArrowIpcWriterStartFile(struct ArrowIpcWriter* writer,
                                       struct ArrowError* error) {
  NANOARROW_DCHECK(writer != NULL && writer->private_data != NULL);

  struct ArrowIpcWriterPrivate* private =
      (struct ArrowIpcWriterPrivate*)writer->private_data;

  NANOARROW_DCHECK(!private->writing_file && private->bytes_written == 0);

  struct ArrowBufferView magic = {
      .data.data = NANOARROW_IPC_FILE_PADDED_MAGIC,
      .size_bytes = sizeof(NANOARROW_IPC_FILE_PADDED_MAGIC),
  };
  NANOARROW_RETURN_NOT_OK(
      ArrowIpcOutputStreamWrite(&private->output_stream, magic, error));

  private->writing_file = 1;
  private->bytes_written = magic.size_bytes;
  return NANOARROW_OK;
}

ArrowErrorCode ArrowIpcWriterFinalizeFile(struct ArrowIpcWriter* writer,
                                          struct ArrowError* error) {
  NANOARROW_DCHECK(writer != NULL && writer->private_data != NULL);

  struct ArrowIpcWriterPrivate* private =
      (struct ArrowIpcWriterPrivate*)writer->private_data;

  NANOARROW_DCHECK(private->writing_file);

  NANOARROW_ASSERT_OK(ArrowBufferResize(&private->buffer, 0, 0));
  NANOARROW_RETURN_NOT_OK(
      ArrowIpcEncoderEncodeFooter(&private->encoder, &private->footer, error));
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowIpcEncoderFinalizeBuffer(&private->encoder, /*encapsulate=*/0,
                                    &private->buffer),
      error);

  _NANOARROW_CHECK_RANGE(private->buffer.size_bytes, 0, INT32_MAX);
  int32_t size = (int32_t) private->buffer.size_bytes;
  // we don't pad the magic at the end of the file
  struct ArrowStringView unpadded_magic = ArrowCharView(NANOARROW_IPC_FILE_PADDED_MAGIC);
  NANOARROW_DCHECK(unpadded_magic.size_bytes == 6);

  // just append to private->buffer instead of queueing two more tiny writes
  NANOARROW_RETURN_NOT_OK_WITH_ERROR(
      ArrowBufferReserve(&private->buffer, sizeof(size) + unpadded_magic.size_bytes),
      error);

  if (ArrowIpcSystemEndianness() == NANOARROW_IPC_ENDIANNESS_BIG) {
    size = (int32_t)bswap32((uint32_t)size);
  }
  NANOARROW_ASSERT_OK(ArrowBufferAppendInt32(&private->buffer, size));
  NANOARROW_ASSERT_OK(ArrowBufferAppendStringView(&private->buffer, unpadded_magic));

  NANOARROW_RETURN_NOT_OK(ArrowIpcOutputStreamWrite(
      &private->output_stream, ArrowBufferToBufferView(&private->buffer), error));
  private->bytes_written += private->buffer.size_bytes;
  return NANOARROW_OK;
}
