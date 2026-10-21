/* Strict UTF-8 validation (RFC 3629): no overlong forms, no surrogates,
   nothing above U+10FFFF. nanoarrow's full validation level reads offsets
   and dictionary indices but not string contents, so zuarrow adds this
   pass for utf8, large_utf8 and utf8_view (design sections 1.3, 6.11). */
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

int zar_view_validate_utf8(const struct ArrowArrayView *view, const char *path,
                           struct ArrowError *error) {
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
