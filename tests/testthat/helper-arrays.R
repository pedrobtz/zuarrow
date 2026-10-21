# Arrays and streams for tests, built from raw buffers through zuarrow's
# internal constructors. They skip validation, so a test can make a
# malformed array on purpose. Stage 3's arrow_array() is the public way.
test_array <- function(
  schema,
  length,
  buffers,
  null_count = 0,
  offset = 0,
  children = list(),
  dictionary = NULL
) {
  if (is.character(schema)) {
    schema <- arrow_schema(schema)
  }
  .Call(
    zuarrow:::zar_c_array_from_buffers,
    schema,
    test_array_spec(length, buffers, null_count, offset, children, dictionary)
  )
}

test_array_spec <- function(
  length,
  buffers,
  null_count = 0,
  offset = 0,
  children = list(),
  dictionary = NULL
) {
  list(
    length = length,
    null_count = null_count,
    offset = offset,
    buffers = buffers,
    children = children,
    dictionary = dictionary
  )
}

test_int32 <- function(values) {
  test_array(
    "i",
    length(values),
    list(NULL, writeBin(as.integer(values), raw(), endian = "little"))
  )
}

test_utf8 <- function(offsets, data) {
  test_array(
    "u",
    length(offsets) - 1L,
    list(NULL, writeBin(as.integer(offsets), raw(), endian = "little"), data)
  )
}

test_stream <- function(schema, arrays) {
  if (is.character(schema)) {
    schema <- arrow_schema(schema)
  }
  .Call(zuarrow:::zar_c_stream_from_arrays, schema, arrays)
}
