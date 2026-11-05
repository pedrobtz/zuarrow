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

arrow_info_length <- function(array) {
  .Call(zuarrow:::zar_c_array_info, array)$length
}

# A schema with an extension name, for section 6.6's tests.
ext_schema <- function(format, name, metadata = raw()) {
  test_schema(list(
    format = format,
    name = "",
    flags = 2L,
    metadata = list(
      "ARROW:extension:name" = charToRaw(name),
      "ARROW:extension:metadata" = metadata
    ),
    children = list(),
    dictionary = NULL
  ))
}

# A stream from a producer other than zuarrow's reader, whose get_next()
# always fails. With `schema_fails = TRUE` its get_schema() fails too.
test_failing_stream <- function(schema, schema_fails = FALSE) {
  .Call(zuarrow:::zar_c_test_failing_stream, schema, schema_fails)
}

# Validity bytes for `valid`, a logical vector.
test_validity <- function(valid) {
  packBits(c(valid, logical((-length(valid)) %% 8L)), "raw")
}

# A dictionary<int32, format> array. `indices` are 0-based, NA for a null
# row; `values` is the dictionary's array spec.
test_dict_array <- function(format, indices, values) {
  schema <- test_schema(list(
    format = "i",
    name = "",
    flags = 2L,
    metadata = NULL,
    children = list(),
    dictionary = zspec(format)
  ))
  nulls <- is.na(indices)
  test_array(
    schema,
    length(indices),
    list(
      if (any(nulls)) test_validity(!nulls),
      le_int(ifelse(nulls, 0, indices), 4L)
    ),
    null_count = sum(nulls),
    dictionary = values
  )
}

# A run_end_encoded<int32, format> array; `values` is the values child's
# array spec.
test_ree_array <- function(format, run_ends, values) {
  schema <- test_schema(zspec(
    "+r",
    children = list(zspec("i", "run_ends", flags = 0L), zspec(format, "values"))
  ))
  test_array(
    schema,
    run_ends[length(run_ends)],
    list(),
    children = list(
      test_array_spec(length(run_ends), list(NULL, le_int(run_ends, 4L))),
      values
    )
  )
}
