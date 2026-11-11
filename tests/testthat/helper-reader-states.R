# Helpers of test-reader-states.R: small IPC inputs and the states a
# reader reaches over them.

# Three one-row batches whose second holds invalid UTF-8: the first reads,
# the second fails, and the third would read if the reader skipped on.
three_batches <- function(format = "stream", broken = TRUE) {
  df <- data.frame(i = 1:3, s = c("aaa", "xQx", "ccc"))
  bytes <- arrow_write(df, NULL, format = format, batch = 1)
  if (broken) {
    bytes <- patch_bytes(bytes, "xQx", as.raw(c(0x78, 0xff, 0x78)))
  }
  bytes
}

row_of <- function(k) {
  data.frame(i = k, s = c("aaa", "xQx", "ccc")[k])
}

expect_failed_state <- function(stream, class, schema) {
  # Every later call fails the same way and returns no batch.
  for (k in 1:3) {
    expect_error(arrow_next(stream), class = class)
  }
  expect_error(arrow_to_r(stream), class = class)
  # The schema is still there.
  expect_true(arrow_equal(arrow_schema(stream), schema))
}

# A lazy reader copies a raw vector, so a stream moved out of its handle
# holds all it reads once no R object refers to the input.
moved_readers <- function(chained) {
  open <- function(format) {
    source <- three_batches(format, broken = FALSE)
    if (chained) {
      source <- list(source, source)
    }
    test_move(arrow_read(source, lazy = TRUE))
  }
  moved <- lapply(c(stream = "stream", file = "file"), open)
  heap_churn()
  moved
}
