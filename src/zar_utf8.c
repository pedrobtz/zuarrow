/* Strict UTF-8 validation (RFC 3629): no overlong forms, no surrogates,
   nothing above U+10FFFF. nanoarrow's full validation level reads offsets
   and dictionary indices but not string contents, so zuarrow adds this
   pass for utf8, large_utf8 and utf8_view (design sections 1.3, 6.11). */
#include <stdio.h>

#include "zar.h"

int64_t zar_utf8_invalid_at(const uint8_t *s, int64_t n) {
  int64_t i = 0;
  while (i < n) {
    uint8_t c = s[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    int64_t start = i;
    int len;
    uint32_t cp;
    if (c >= 0xc2 && c <= 0xdf) {
      len = 2;
      cp = c & 0x1f;
    } else if (c >= 0xe0 && c <= 0xef) {
      len = 3;
      cp = c & 0x0f;
    } else if (c >= 0xf0 && c <= 0xf4) {
      len = 4;
      cp = c & 0x07;
    } else {
      return start;
    }
    if (n - i < len) return start;
    for (int k = 1; k < len; k++) {
      uint8_t cc = s[i + k];
      if ((cc & 0xc0) != 0x80) return start;
      cp = (cp << 6) | (cc & 0x3f);
    }
    if ((len == 3 && cp < 0x800) || (len == 4 && cp < 0x10000) ||
        (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff) {
      return start;
    }
    i += len;
  }
  return -1;
}

/* nanoarrow's full level does not read binary-view or string-view
   structs, so a view could name a buffer or a range that does not exist.
   Checks every non-null view of this node: an inline length of at most 12
   bytes, or a buffer index and range inside the variadic buffers. */
static int zar_check_views(const struct ArrowArrayView *view, const char *path,
                           struct ArrowError *error) {
  const union ArrowBinaryView *views = view->buffer_views[1].data.as_binary_view;
  for (int64_t i = 0; i < view->length; i++) {
    if (ArrowArrayViewIsNull(view, i)) continue;
    const union ArrowBinaryView *v = &views[view->offset + i];
    int32_t size = v->inlined.size;
    if (size < 0) {
      ArrowErrorSet(error, "%sview %ld has a negative length", path, (long)i);
      return EINVAL;
    }
    if (size <= NANOARROW_BINARY_VIEW_INLINE_SIZE) continue;
    int32_t b = v->ref.buffer_index;
    int64_t offset = v->ref.offset;
    if (b < 0 || b >= view->n_variadic_buffers || offset < 0 ||
        offset > view->variadic_buffer_sizes[b] - size) {
      ArrowErrorSet(error, "%sview %ld points outside its data buffers", path, (long)i);
      return EINVAL;
    }
  }
  return NANOARROW_OK;
}

int zar_view_check_layout(const struct ArrowArrayView *view, const char *path,
                          struct ArrowError *error) {
  if (view->storage_type == NANOARROW_TYPE_BINARY_VIEW ||
      view->storage_type == NANOARROW_TYPE_STRING_VIEW) {
    int code = zar_check_views(view, path, error);
    if (code != NANOARROW_OK) return code;
  }
  char child[256];
  for (int64_t i = 0; i < view->n_children; i++) {
    snprintf(child, sizeof(child), "%schild %ld: ", path, (long)i);
    int code = zar_view_check_layout(view->children[i], child, error);
    if (code != NANOARROW_OK) return code;
  }
  if (view->dictionary != NULL) {
    snprintf(child, sizeof(child), "%sdictionary: ", path);
    return zar_view_check_layout(view->dictionary, child, error);
  }
  return NANOARROW_OK;
}

int zar_view_validate_utf8(const struct ArrowArrayView *view, const char *path,
                           struct ArrowError *error) {
  if (path[0] == '\0') {
    int code = zar_view_check_layout(view, path, error);
    if (code != NANOARROW_OK) return code;
  }
  switch (view->storage_type) {
    case NANOARROW_TYPE_STRING:
    case NANOARROW_TYPE_LARGE_STRING:
    case NANOARROW_TYPE_STRING_VIEW:
      for (int64_t i = 0; i < view->length; i++) {
        if (ArrowArrayViewIsNull(view, i)) continue;
        struct ArrowBufferView bytes = ArrowArrayViewGetBytesUnsafe(view, i);
        int64_t at = zar_utf8_invalid_at(bytes.data.as_uint8, bytes.size_bytes);
        if (at >= 0) {
          ArrowErrorSet(error, "%selement %ld is not valid UTF-8 at byte %ld",
                        path, (long)i, (long)at);
          return EINVAL;
        }
      }
      break;
    default:
      break;
  }
  char child[256];
  for (int64_t i = 0; i < view->n_children; i++) {
    snprintf(child, sizeof(child), "%schild %ld: ", path, (long)i);
    int code = zar_view_validate_utf8(view->children[i], child, error);
    if (code != NANOARROW_OK) return code;
  }
  if (view->dictionary != NULL) {
    snprintf(child, sizeof(child), "%sdictionary: ", path);
    return zar_view_validate_utf8(view->dictionary, child, error);
  }
  return NANOARROW_OK;
}
