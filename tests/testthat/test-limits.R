# Every arrow_limits() limit straddled at its input's exact measure: a
# limit error at measure - 1, and the full read at measure and measure + 1,
# on every source kind and framing that reaches it, eager and lazy. An
# off-by-one, or a limit counted in another unit on one path, fails here.

test_that("max_bytes binds at the input's size on every source", {
  df <- data.frame(x = 1:3, s = c("a", "b", "c"))
  for (format in c("stream", "file")) {
    bytes <- arrow_write(df, NULL, format = format)
    expect_straddle(
      bytes,
      "max_bytes",
      function(times) times * length(bytes),
      format
    )
  }
})

test_that("max_message binds at a message body's size", {
  for (format in c("stream", "file")) {
    bytes <- arrow_write(data.frame(x = 1:1000), NULL, format = format)
    parts <- message_parts(bytes, format)
    expect_identical(names(which.max(parts)), "body")
    expect_straddle(bytes, "max_message", function(times) max(parts), format)
  }
})

test_that("max_message binds at a header's size, and a file footer's", {
  for (format in c("stream", "file")) {
    bytes <- arrow_write(
      data.frame(x = 1L),
      NULL,
      format = format,
      metadata = c(k = strrep("a", 3000))
    )
    parts <- message_parts(bytes, format)
    # A file's footer repeats the schema, so it is the largest part there.
    biggest <- if (format == "file") "footer" else "header"
    expect_identical(names(which.max(parts)), biggest)
    expect_straddle(bytes, "max_message", function(times) max(parts), format)
  }
})

test_that("max_message binds at a compressed buffer's length prefix", {
  for (format in c("stream", "file")) {
    for (compression in c("lz4", "zstd")) {
      bytes <- arrow_write(
        data.frame(x = rep(1L, 1000)),
        NULL,
        format = format,
        compression = compression
      )
      # The values buffer decodes to 4000 bytes, more than any part.
      parts <- message_parts(bytes, format)
      expect_lt(max(parts), 4000)
      expect_straddle(
        bytes,
        "max_message",
        function(times) 4000,
        paste(format, compression)
      )
    }
  }
})

test_that("max_batch_rows binds at a record batch's rows", {
  for (format in c("stream", "file")) {
    bytes <- arrow_write(data.frame(x = 1:7), NULL, format = format)
    expect_straddle(bytes, "max_batch_rows", function(times) 7, format)
  }
})

test_that("max_batch_rows binds at a dictionary's values", {
  for (format in c("stream", "file")) {
    f <- factor(c("b", "c", "b"), levels = letters[1:10])
    bytes <- arrow_write(data.frame(f = f), NULL, format = format)
    expect_straddle(bytes, "max_batch_rows", function(times) 10, format)
  }
})

test_that("max_depth binds at the schema's nesting, read and converted", {
  df <- data.frame(x = 1L)
  df$s <- data.frame(y = 1L)
  df$s$t <- data.frame(z = 2L)
  spec <- .Call(zuarrow:::zar_c_schema_to_spec, arrow_schema(arrow_array(df)))
  depth <- schema_depth(spec) - 1
  expect_identical(depth, 3)
  for (format in c("stream", "file")) {
    bytes <- arrow_write(df, NULL, format = format)
    expect_straddle(bytes, "max_depth", function(times) depth, format)
  }
})

test_that("max_dictionary binds at the bytes deltas build", {
  # Each delta onto a dictionary that holds values copies all of it: here
  # 4 * (3 + 5) bytes, then 4 * (3 + 5 + 2), so 72 in all. The first
  # dictionary is no copy and does not count.
  bytes <- delta_stream(c(3, 5, 2))
  expect_identical(
    arrow_read(bytes)$x,
    c(10L, 30L, 10L, 80L, 10L, 100L)
  )
  expect_straddle(bytes, "max_dictionary", function(times) 72)
})

test_that("max_batch_rows binds at the values deltas extend a dictionary to", {
  # 3 + 5 + 2 values, while every batch holds two rows.
  bytes <- delta_stream(c(3, 5, 2))
  expect_straddle(bytes, "max_batch_rows", function(times) 10)
})
