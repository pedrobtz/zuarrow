# The reader's rules for untrusted input (design section 6.7), each broken
# alone in input taken apart and rebuilt with helper-ipc.R.

test_that("a stream must start with a schema", {
  bytes <- factor_stream(c("a", "b"))
  m <- ipc_messages(bytes)
  no_schema <- c(
    ipc_message_bytes(bytes, m[[2]]),
    ipc_message_bytes(bytes, m[[3]]),
    ipc_eos()
  )
  expect_error(arrow_read(no_schema), class = "zuarrow_format_error")
})

test_that("a stream message after the schema is a batch or a dictionary", {
  bytes <- factor_stream(c("a", "b"))
  m <- ipc_messages(bytes)
  two_schemas <- c(
    ipc_message_bytes(bytes, m[[1]]),
    ipc_message_bytes(bytes, m[[1]]),
    ipc_eos()
  )
  expect_error(arrow_read(two_schemas), class = "zuarrow_format_error")
})

test_that("a dictionary batch must hold a record batch", {
  bytes <- factor_stream(c("a", "b"))
  m <- ipc_messages(bytes)
  # The hand-built message reads when it is whole.
  whole <- c(
    ipc_message_bytes(bytes, m[[1]]),
    ipc_utf8_dictionary(0, c("a", "b")),
    ipc_message_bytes(bytes, m[[3]]),
    ipc_eos()
  )
  expect_identical(arrow_read(whole)$f, factor(c("a", "b")))
  no_data <- c(
    ipc_message_bytes(bytes, m[[1]]),
    ipc_dictionary_message(0, 0, list(), list(), raw(), data = FALSE),
    ipc_eos()
  )
  expect_error(arrow_read(no_data), class = "zuarrow_format_error")
})

test_that("a delta dictionary batch extends the dictionary", {
  bytes <- factor_stream(c("a", "b"))
  m <- ipc_messages(bytes)
  delta <- c(
    ipc_message_bytes(bytes, m[[1]]),
    ipc_utf8_dictionary(0, character()),
    ipc_utf8_dictionary(0, c("a", "b"), is_delta = TRUE),
    ipc_message_bytes(bytes, m[[3]]),
    ipc_eos()
  )
  expect_identical(arrow_read(delta)$f, factor(c("a", "b")))
  # A delta onto a dictionary that already holds values appends to it
  # (tools/patches/0015-dictionary-delta-concat.patch, #81).
  later <- factor_stream(c("a", "b", "c"), "c")
  later_batch <- ipc_message_bytes(later, ipc_messages(later)[[3]])
  extend <- c(
    ipc_message_bytes(bytes, m[[1]]),
    ipc_message_bytes(bytes, m[[2]]),
    ipc_message_bytes(bytes, m[[3]]),
    ipc_utf8_dictionary(0, "c", is_delta = TRUE),
    later_batch,
    ipc_eos()
  )
  expect_identical(
    arrow_read(extend)$f,
    factor(c("a", "b", "c"), levels = c("a", "b", "c"))
  )
})

test_that("deltas extend a fixed-width dictionary, nulls included", {
  first <- int_dictionary_stream(c(0, 1), c(10, 20))
  m <- ipc_messages(first)
  stream <- c(
    ipc_message_bytes(first, m[[1]]),
    ipc_message_bytes(first, m[[2]]),
    ipc_message_bytes(first, m[[3]]),
    ipc_int32_dictionary(0, c(30, NA), is_delta = TRUE),
    ipc_dictionary_codes(c(2, 3)),
    ipc_int32_dictionary(0, 40, is_delta = TRUE),
    ipc_dictionary_codes(c(4, 0)),
    ipc_eos()
  )
  expect_identical(arrow_read(stream)$x, c(10L, 20L, 30L, NA, 40L, 10L))
})

test_that("the dictionaries that deltas build are bounded (#101)", {
  # Each delta copies the whole dictionary, and each batch keeps the
  # version it was decoded with, so n deltas of k values build about
  # n^2 * k / 2 values. Here n = 40 and k = 100.
  first <- int_dictionary_stream(0, 1)
  m <- ipc_messages(first)
  batch <- function(code) {
    bytes <- int_dictionary_stream(code, seq_len(code + 1))
    ipc_message_bytes(bytes, ipc_messages(bytes)[[3]])
  }
  n <- 40
  k <- 100
  deltas <- lapply(seq_len(n), function(i) {
    c(
      ipc_int32_dictionary(0, seq_len(k) + i * k, is_delta = TRUE),
      batch(i * k)
    )
  })
  stream <- c(
    ipc_message_bytes(first, m[[1]]),
    ipc_message_bytes(first, m[[2]]),
    ipc_message_bytes(first, m[[3]]),
    unlist(deltas),
    ipc_eos()
  )
  # Each batch takes the last value of the delta before it.
  expected <- c(1L, as.integer((seq_len(n) + 1) * k))

  # Under the limits, the stream reads as before.
  expect_identical(arrow_read(stream)$x, expected)
  # About 4 * 100 * 40^2 / 2 = 320 000 bytes are built in all.
  expect_identical(
    arrow_read(stream, limits = arrow_limits(max_dictionary = 4e5))$x,
    expected
  )
  expect_error(
    arrow_read(stream, limits = arrow_limits(max_dictionary = 1e5)),
    class = "zuarrow_limit_error"
  )
  expect_error(
    arrow_to_r(
      arrow_read(
        stream,
        lazy = TRUE,
        limits = arrow_limits(max_dictionary = 1e5)
      )
    ),
    class = "zuarrow_limit_error"
  )
  # One dictionary may hold no more values than one batch may.
  expect_error(
    arrow_read(stream, limits = arrow_limits(max_batch_rows = 2000)),
    class = "zuarrow_limit_error"
  )
  # Nor more bytes than one message may.
  expect_error(
    arrow_read(stream, limits = arrow_limits(max_message = 8000)),
    class = "zuarrow_limit_error"
  )
})

test_that("a file's blocks must name messages of their kind", {
  bytes <- arrow_write(data.frame(f = factor("a"), g = factor("b")), NULL)
  m <- ipc_messages(bytes, 8)
  types <- vapply(m, function(x) x$type, 0)
  expect_identical(types, c(1, 2, 2, 3))
  # A dictionary block that names the record batch.
  expect_error(
    arrow_read(ipc_swap_block(bytes, m[[4]], m[[2]])),
    class = "zuarrow_format_error"
  )
  # A record batch block that names a dictionary batch.
  expect_error(
    arrow_read(ipc_swap_block(bytes, m[[2]], m[[4]])),
    class = "zuarrow_format_error"
  )
})

test_that("max_dictionary defaults to 256 MiB, under the format ceiling", {
  limits <- arrow_limits()
  expect_identical(limits$max_dictionary, 2^28)
  expect_lt(limits$max_dictionary, limits$max_message)
})

test_that("a file may not replace a dictionary", {
  bytes <- arrow_write(data.frame(f = factor("a"), g = factor("b")), NULL)
  m <- ipc_messages(bytes, 8)
  # Both dictionary blocks name dictionary 0, neither as a delta.
  expect_error(
    arrow_read(ipc_swap_block(bytes, m[[2]], m[[3]])),
    class = "zuarrow_format_error"
  )
})

test_that("a file must start with a schema", {
  bytes <- arrow_write(data.frame(f = factor("a")), NULL)
  m <- ipc_messages(bytes, 8)
  schema_end <- m[[1]]$start + m[[1]]$meta + m[[1]]$body
  no_schema <- c(
    bytes[1:8],
    ipc_message_bytes(bytes, m[[3]]),
    bytes[(schema_end + 1):length(bytes)]
  )
  expect_error(arrow_read(no_schema), class = "zuarrow_format_error")
  # An end-of-stream marker where the schema should be, the footer intact.
  eos_first <- bytes
  eos_first[9:16] <- ipc_eos()
  expect_error(arrow_read(eos_first), class = "zuarrow_format_error")
})

test_that("a message body over max_message is a limit error", {
  bytes <- arrow_write(data.frame(x = 1:1000), NULL, format = "stream")
  m <- ipc_messages(bytes)
  # The headers fit and the body does not, so the body check is the one hit.
  expect_lt(max(vapply(m, function(x) x$meta, 0)), 1000)
  expect_gt(m[[2]]$body, 1000)
  expect_error(
    arrow_read(bytes, limits = arrow_limits(max_message = 1000)),
    class = "zuarrow_limit_error"
  )
})

test_that("a compressed buffer must decode to its length prefix", {
  for (compression in c("lz4", "zstd")) {
    bytes <- arrow_write(
      data.frame(x = rep(1L, 1000)),
      NULL,
      format = "stream",
      compression = compression
    )
    # The values buffer's prefix: the first 4000 as an int64 in the body
    # (an LZ4 frame repeats the size in its own header, after it).
    batch <- ipc_messages(bytes)[[2]]
    body_start <- batch$start + batch$meta
    at <- bytes_at(bytes, le_int(4000, 8L)) - 1L
    at <- min(at[at >= body_start])
    with_prefix <- function(n) {
      bytes[at + 1:8] <- le_int(n, 8L)
      bytes
    }
    # A prefix that claims too few bytes: the decoder stops at it.
    expect_error(
      arrow_read(with_prefix(3999)),
      class = "zuarrow_limit_error"
    )
    # A prefix that claims too many: zukomp, told the exact size, reports
    # the short stream as invalid data, which is a codec error.
    expect_error(
      arrow_read(with_prefix(4001)),
      class = "zuarrow_codec_error"
    )
  }
})

test_that("a delta extends a large_utf8 dictionary", {
  first <- dictionary_stream(
    c(0, 1),
    zspec("U"),
    test_array_spec(2, list(NULL, le_int(c(0, 1, 2), 8L), charToRaw("ab")))
  )
  m <- ipc_messages(first)
  # 64-bit offsets that start past the data's first byte, so the delta's
  # offsets must be rebased onto the end of the dictionary's data.
  delta <- ipc_buffers_dictionary(
    0,
    2,
    nodes = list(c(2, 0)),
    buffers = list(NULL, le_int(c(1, 3, 4), 8L), charToRaw("xccd")),
    is_delta = TRUE
  )
  stream <- c(
    ipc_message_bytes(first, m[[1]]),
    ipc_message_bytes(first, m[[2]]),
    ipc_message_bytes(first, m[[3]]),
    delta,
    ipc_dictionary_codes(c(2, 3, 0)),
    ipc_eos()
  )
  expect_identical(
    arrow_read(stream)$x,
    factor(c("a", "b", "cc", "d", "a"), levels = c("a", "b", "cc", "d"))
  )
})

test_that("a delta extends a bool dictionary across a byte boundary", {
  values <- c(TRUE, FALSE, TRUE, TRUE, FALSE, FALSE, TRUE)
  first <- dictionary_stream(
    c(0, 6),
    zspec("b"),
    test_array_spec(7, list(NULL, ipc_bits(values)))
  )
  m <- ipc_messages(first)
  added <- c(FALSE, NA, TRUE)
  delta <- ipc_buffers_dictionary(
    0,
    3,
    nodes = list(c(3, 1)),
    buffers = list(ipc_validity(!is.na(added)), ipc_bits(added %in% TRUE)),
    is_delta = TRUE
  )
  stream <- c(
    ipc_message_bytes(first, m[[1]]),
    ipc_message_bytes(first, m[[2]]),
    ipc_message_bytes(first, m[[3]]),
    delta,
    ipc_dictionary_codes(0:9),
    ipc_eos()
  )
  expect_identical(arrow_read(stream)$x, c(TRUE, TRUE, values, added))
})

test_that("a delta onto a struct-valued dictionary is a format error", {
  struct <- function(n, a) {
    test_array_spec(
      n,
      list(NULL),
      children = list(test_array_spec(n, list(NULL, le_int(a, 4L))))
    )
  }
  first <- dictionary_stream(
    c(0, 1),
    zspec("+s", children = list(zspec("i", "a"))),
    struct(2, c(5, 6))
  )
  m <- ipc_messages(first)
  head <- c(
    ipc_message_bytes(first, m[[1]]),
    ipc_message_bytes(first, m[[2]]),
    ipc_message_bytes(first, m[[3]])
  )
  # The stream reads without the delta.
  expect_identical(
    arrow_read(c(head, ipc_eos()))$x,
    data.frame(a = c(5L, 6L))
  )
  delta <- ipc_buffers_dictionary(
    0,
    1,
    nodes = list(c(1, 0), c(1, 0)),
    buffers = list(NULL, NULL, le_int(7, 4L)),
    is_delta = TRUE
  )
  stream <- c(head, delta, ipc_dictionary_codes(c(2, 0)), ipc_eos())
  expect_error(arrow_read(stream), class = "zuarrow_format_error")
})
