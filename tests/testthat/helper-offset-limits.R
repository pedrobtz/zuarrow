# Helpers of test-offset-limits.R.

format_of_array <- function(x, ...) format(arrow_schema(arrow_array(x, ...)))

# A struct schema of one field `x` of `format`, with `children`.
struct_of <- function(format, children = list()) {
  test_schema(zspec("+s", children = list(zspec(format, "x", children))))
}

# A string_view array of strings of at most 12 bytes, which a view holds
# inline, so the array needs no data buffer.
inline_views <- function(x) {
  views <- unlist(lapply(x, function(s) {
    bytes <- charToRaw(s)
    c(le_int(length(bytes), 4L), bytes, raw(12L - length(bytes)))
  }))
  test_array("vu", length(x), list(NULL, views, le_int(numeric(), 8L)))
}
