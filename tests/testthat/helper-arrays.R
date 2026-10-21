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

# Little-endian bytes of whole numbers below 2^53 in magnitude, as `bytes`
# wide two's complement integers.
le_int <- function(values, bytes = 8L) {
  unlist(lapply(values, function(v) {
    neg <- v < 0
    m <- abs(v)
    out <- as.integer(floor(m / 256^(seq_len(bytes) - 1L)) %% 256)
    if (neg) {
      out <- 255L - out
      carry <- 1L
      for (k in seq_len(bytes)) {
        out[k] <- out[k] + carry
        carry <- out[k] %/% 256L
        out[k] <- out[k] %% 256L
      }
    }
    as.raw(out)
  }))
}

# Little-endian bytes from big-endian hex, for values past 2^53.
le_hex <- function(hex) {
  rev(as.raw(strtoi(
    substring(hex, seq(1, nchar(hex), 2), seq(2, nchar(hex), 2)),
    16L
  )))
}

test_fixed <- function(format, values, bytes, null_count = 0, validity = NULL) {
  test_array(
    format,
    length(values),
    list(validity, le_int(values, bytes)),
    null_count = null_count
  )
}

test_schema <- function(spec) {
  .Call(zuarrow:::zar_c_schema_from_spec, spec)
}

zspec <- function(format, name = "", children = list(), flags = 2L) {
  list(
    format = format,
    name = name,
    flags = flags,
    metadata = NULL,
    children = children,
    dictionary = NULL
  )
}

format_of <- function(schema) {
  .Call(zuarrow:::zar_c_schema_to_spec, schema)$format
}
