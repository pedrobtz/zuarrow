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
  # The vendored decoder cannot yet concatenate a delta onto a dictionary
  # that holds values; until it can, that is a format error, not a misread.
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
  expect_error(arrow_read(extend), class = "zuarrow_format_error")
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
