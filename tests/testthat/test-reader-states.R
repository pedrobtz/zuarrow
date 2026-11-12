# What a reader stream (arrow_read(lazy = TRUE)) and a chain of them do in
# each state: reading, failed, ended, released, moved. A failed reader
# stays failed (#207), so it never resumes past a bad message.

test_that("a reader that fails stays failed, in both framings", {
  for (format in c("stream", "file")) {
    stream <- arrow_read(three_batches(format), lazy = TRUE)
    schema <- arrow_schema(stream)
    expect_identical(arrow_next(stream), row_of(1L), info = format)
    expect_error(arrow_next(stream), class = "zuarrow_format_error")
    expect_failed_state(stream, "zuarrow_format_error", schema)
  }
})

test_that("a reader that fails a limit stays failed, and keeps its class", {
  limits <- arrow_limits(max_batch_rows = 1)
  df <- data.frame(i = c(1L, 2L, 3L))
  for (format in c("stream", "file")) {
    # Batches of 1, 2 and 1 rows: the second is over the limit.
    arrays <- lapply(list(1L, 2:3, 1L), function(k) {
      arrow_array(df[k, , drop = FALSE])
    })
    source <- test_stream(arrow_schema(arrays[[1]]), arrays)
    bytes <- arrow_write(source, NULL, format = format)
    stream <- arrow_read(bytes, lazy = TRUE, limits = limits)
    schema <- arrow_schema(stream)
    expect_identical(arrow_next(stream), data.frame(i = 1L), info = format)
    expect_error(arrow_next(stream), class = "zuarrow_limit_error")
    expect_failed_state(stream, "zuarrow_limit_error", schema)
  }
})

test_that("a reader that fails on its first batch returns no batch", {
  df <- data.frame(s = "xQx")
  bytes <- arrow_write(df, NULL, format = "stream")
  bytes <- patch_bytes(bytes, "xQx", as.raw(c(0x78, 0xff, 0x78)))
  stream <- arrow_read(bytes, lazy = TRUE)
  expect_failed_state(stream, "zuarrow_format_error", arrow_schema(stream))
})

test_that("an ended reader stays ended and keeps its schema", {
  for (format in c("stream", "file")) {
    stream <- arrow_read(three_batches(format, broken = FALSE), lazy = TRUE)
    schema <- arrow_schema(stream)
    for (k in 1:3) {
      expect_identical(arrow_next(stream), row_of(k), info = format)
    }
    for (k in 1:3) {
      expect_null(arrow_next(stream))
    }
    expect_identical(nrow(arrow_to_r(stream)), 0L)
    expect_true(arrow_equal(arrow_schema(stream), schema))
  }
})

test_that("arrow_to_r() after arrow_next() reads the rest", {
  stream <- arrow_read(three_batches(broken = FALSE), lazy = TRUE)
  expect_identical(arrow_next(stream), row_of(1L))
  rest <- arrow_to_r(stream)
  expect_identical(rest, data.frame(i = 2:3, s = c("xQx", "ccc")))
  expect_null(arrow_next(stream))
})

test_that("columns are selected before the first batch only", {
  select <- function(stream, idx) {
    zuarrow:::zar_check(.Call(zuarrow:::zar_c_reader_select, stream, idx))
  }
  stream <- arrow_read(three_batches(broken = FALSE), lazy = TRUE)
  expect_true(select(stream, 1L))
  expect_identical(arrow_next(stream), data.frame(s = "aaa"))
  expect_error(select(stream, 0L), class = "zuarrow_handle_error")
  # The refused selection changed nothing.
  expect_identical(arrow_next(stream), data.frame(s = "xQx"))

  # A failed first batch has started the reader too.
  bad <- arrow_read(
    three_batches(),
    lazy = TRUE,
    limits = arrow_limits(max_batch_rows = 0)
  )
  expect_error(arrow_next(bad), class = "zuarrow_limit_error")
  expect_error(select(bad, 0L), class = "zuarrow_handle_error")

  # A chain is not a reader, so it selects nothing.
  bytes <- three_batches(broken = FALSE)
  chain <- arrow_read(list(bytes, bytes), lazy = TRUE)
  expect_error(select(chain, 0L), class = "zuarrow_handle_error")
})

test_that("a released reader or chain is a handle error, mid-stream", {
  bytes <- three_batches(broken = FALSE)
  for (stream in list(
    arrow_read(bytes, lazy = TRUE),
    arrow_read(list(bytes, bytes), lazy = TRUE)
  )) {
    expect_identical(arrow_next(stream), row_of(1L))
    test_release(stream)
    expect_error(arrow_next(stream), class = "zuarrow_handle_error")
    expect_error(arrow_schema(stream), class = "zuarrow_handle_error")
    expect_error(arrow_to_r(stream), class = "zuarrow_handle_error")
  }
})

test_that("a chain whose later source fails stays failed there", {
  good <- three_batches(broken = FALSE)
  chain <- arrow_read(list(good, three_batches(), good), lazy = TRUE)
  schema <- arrow_schema(chain)
  for (k in 1:3) {
    expect_identical(arrow_next(chain), row_of(k))
  }
  expect_identical(arrow_next(chain), row_of(1L))
  expect_error(arrow_next(chain), class = "zuarrow_format_error")
  # Neither the failed source's third batch nor the third source is read.
  expect_failed_state(chain, "zuarrow_format_error", schema)
})

test_that("a chain whose later source fails at its schema is never returned", {
  good <- three_batches(broken = FALSE)
  # The second source stops inside its schema message.
  for (cut in list(good[1:20], good[1:4], raw())) {
    expect_error(
      arrow_read(list(good, cut, good), lazy = TRUE),
      class = "zuarrow_format_error"
    )
    expect_error(
      arrow_read(list(good, cut, good)),
      class = "zuarrow_format_error"
    )
  }
})

test_that("an ended chain stays ended and keeps the last source's schema", {
  good <- three_batches(broken = FALSE)
  # Sources with a schema and no batch, which the chain passes over.
  schema <- arrow_schema(arrow_read(good, lazy = TRUE))
  empty <- arrow_write(test_stream(schema, list()), NULL, format = "stream")
  chain <- arrow_read(list(empty, good, empty), lazy = TRUE)
  schema <- arrow_schema(chain)
  for (k in 1:3) {
    expect_identical(arrow_next(chain), row_of(k))
  }
  for (k in 1:3) {
    expect_null(arrow_next(chain))
  }
  expect_true(arrow_equal(arrow_schema(chain), schema))
})

test_that("a reader moved out of its handle reads after the input is gone", {
  expected <- data.frame(i = 1:3, s = c("aaa", "xQx", "ccc"))
  for (moved in moved_readers(chained = FALSE)) {
    expect_identical(arrow_to_r(moved), expected)
  }
})

test_that("a chain moved out of its handle reads after the input is gone", {
  expected <- data.frame(i = 1:3, s = c("aaa", "xQx", "ccc"))
  for (moved in moved_readers(chained = TRUE)) {
    expect_identical(arrow_to_r(moved), rbind(expected, expected))
  }
})

# A model of a reader over `n` batches whose batch `bad` fails (0 for
# none): what each of arrow_next(), arrow_schema() and arrow_to_r() gives.
test_that("random sequences of calls follow the reader's state model", {
  withr::local_seed(20261111)
  good <- three_batches(broken = FALSE)
  broken <- three_batches()
  all_rows <- data.frame(i = 1:3, s = c("aaa", "xQx", "ccc"))
  runs <- gctorture_sample(seq_len(12L), 4L, cran = 6L)
  for (run in runs) {
    bad <- sample(c(0L, 2L), 1L)
    stream <- arrow_read(if (bad == 0L) good else broken, lazy = TRUE)
    schema <- arrow_schema(stream)
    read <- 0L # batches returned so far
    failed <- FALSE
    for (op in sample(c("next", "schema", "to_r"), 8L, replace = TRUE)) {
      info <- paste("run", run, op, "after", read, "batches")
      if (op == "schema") {
        expect_true(arrow_equal(arrow_schema(stream), schema), info = info)
        next
      }
      fails <- failed || (bad > 0L && read == bad - 1L)
      if (op == "next") {
        if (fails) {
          expect_error(arrow_next(stream), class = "zuarrow_format_error")
          failed <- TRUE
        } else if (read == 3L) {
          expect_null(arrow_next(stream), info = info)
        } else {
          read <- read + 1L
          expect_identical(arrow_next(stream), row_of(read), info = info)
        }
      } else {
        # arrow_to_r() reads the rest, or fails at the bad batch with
        # every batch before it consumed.
        if (fails || (bad > 0L && read < bad)) {
          expect_error(arrow_to_r(stream), class = "zuarrow_format_error")
          failed <- TRUE
        } else {
          rest <- all_rows[seq_len(3L) > read, , drop = FALSE]
          rownames(rest) <- NULL
          expect_identical(arrow_to_r(stream), rest, info = info)
          read <- 3L
        }
      }
    }
  }
})
