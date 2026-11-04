# Interchange with the nanoarrow R package (design section 9). nanoarrow is
# not a dependency: this file is left out of the package tarball
# (.Rbuildignore) and runs from the source tree, in CI by oracles.yaml.

# From test-deferred.R.
test_that("large_string and sliced arrays are deferred", {
  big <- arrow_array(c("p", NA, "qr"), schema = "U")
  x <- arrow_to_r(big, copy = FALSE)
  expect_false(is.null(deferred_info(x)))
  expect_identical(x, c("p", NA, "qr"))

  skip_without_oracle("nanoarrow")
  sliced <- nanoarrow::nanoarrow_array_modify(
    nanoarrow::as_nanoarrow_array(c("a", NA, "c", "d")),
    list(offset = 1L, length = 2L)
  )
  y <- arrow_to_r(sliced, copy = FALSE)
  expect_false(is.null(deferred_info(y)))
  expect_identical(y, c(NA, "c"))
})

# From test-deferred.R.
test_that("a released array is a handle error, not a crash", {
  skip_without_oracle("nanoarrow")
  array <- arrow_array(c("x", "y"))
  x <- arrow_to_r(array, copy = FALSE)
  nanoarrow::nanoarrow_pointer_release(array)
  expect_error(x[[1]], class = "zuarrow_handle_error")
})

# From test-dictionary.R.
test_that("nanoarrow's dictionaries read as factors", {
  skip_without_oracle("nanoarrow")
  f <- factor(c("x", "y", "x"))
  expect_identical(arrow_to_r(nanoarrow::as_nanoarrow_array(f)), f)
})

# From test-direct-paths.R.
test_that("sliced arrays convert from their offset", {
  skip_without_oracle("nanoarrow")
  slice <- function(x, offset, length) {
    nanoarrow::nanoarrow_array_modify(
      nanoarrow::as_nanoarrow_array(x),
      list(offset = offset, length = length)
    )
  }
  expect_identical(
    arrow_to_r(slice(c(1L, NA, 3L, 4L, 5L), 1L, 3L)),
    c(NA, 3L, 4L)
  )
  expect_identical(arrow_to_r(slice(c(0.5, 1.5, NA, 3.5), 2L, 2L)), c(NA, 3.5))
  expect_identical(
    arrow_to_r(slice(c(TRUE, NA, FALSE, TRUE), 1L, 3L)),
    c(NA, FALSE, TRUE)
  )
  expect_identical(
    arrow_to_r(slice(as.Date("2026-10-22") + c(0L, NA, 2L), 1L, 2L)),
    as.Date("2026-10-22") + c(NA, 2L)
  )
  expect_identical(
    arrow_to_r(slice(c("a", NA, "cc", "d"), 1L, 3L)),
    c(NA, "cc", "d")
  )
})

# From test-handles.R.
test_that("a released stream is a handle error", {
  skip_without_oracle("nanoarrow")
  stream <- arrow_stream(data.frame(a = 1:3))
  nanoarrow::nanoarrow_pointer_release(stream)
  expect_error(arrow_next(stream), class = "zuarrow_handle_error")
  expect_error(arrow_to_r(stream), class = "zuarrow_handle_error")
  expect_error(arrow_validate(stream), class = "zuarrow_handle_error")
})

# From test-handles.R.
test_that("an array whose schema was released is a handle error", {
  skip_without_oracle("nanoarrow")
  array <- arrow_array(1:3)
  # nanoarrow returns the array's own schema, the handle's tag, not a copy.
  nanoarrow::nanoarrow_pointer_release(nanoarrow::infer_nanoarrow_schema(array))
  expect_error(arrow_to_r(array), class = "zuarrow_handle_error")
  expect_error(arrow_schema(array), class = "zuarrow_handle_error")
  expect_error(arrow_validate(array), class = "zuarrow_handle_error")
})

# From test-nulls.R.
test_that("a struct with an offset reads its children from that offset", {
  skip_without_oracle("nanoarrow")
  array <- nanoarrow::as_nanoarrow_array(data.frame(x = 1:4, y = letters[1:4]))
  sliced <- nanoarrow::nanoarrow_array_modify(
    array,
    list(offset = 2, length = 2)
  )
  expect_identical(arrow_to_r(sliced), data.frame(x = 3:4, y = c("c", "d")))
})

# From test-read.R.
test_that("a lazy stream crosses to nanoarrow", {
  skip_without_oracle("nanoarrow")
  stream <- arrow_read(test_data("basic.arrows"), lazy = TRUE)
  out <- as.data.frame(nanoarrow::as_nanoarrow_array_stream(stream))
  expect_identical(out$i, basic_df()$i)
})

# From test-registry.R.
test_that("a handler sees a sliced field", {
  skip_without_oracle("nanoarrow")
  local_registration("i", to = function(array, schema) arrow_to_r(array) * 10L)
  array <- nanoarrow::as_nanoarrow_array(data.frame(a = 1:4))
  sliced <- nanoarrow::nanoarrow_array_modify(
    array,
    list(offset = 1, length = 2)
  )
  expect_identical(arrow_to_r(sliced)$a, c(20L, 30L))
})

# From test-stream.R.
test_that("a nanoarrow stream converts through zuarrow", {
  skip_without_oracle("nanoarrow")
  df <- data.frame(x = 1:3, y = c("a", "b", NA))
  stream <- nanoarrow::as_nanoarrow_array_stream(df)
  expect_identical(arrow_to_r(stream), df)
})

# From test-stream.R.
test_that("nanoarrow reads what arrow_stream() writes", {
  skip_without_oracle("nanoarrow")
  df <- data.frame(x = c(1.5, NA), y = c("a", NA), b = c(TRUE, FALSE))
  expect_identical(
    as.data.frame(nanoarrow::convert_array_stream(arrow_stream(df))),
    df
  )
})

# From test-to-r.R.
test_that("string and binary views convert", {
  skip_without_oracle("nanoarrow")
  views <- nanoarrow::as_nanoarrow_array(
    c("short", NA, "a string longer than twelve bytes"),
    schema = nanoarrow::na_string_view()
  )
  expect_identical(
    arrow_to_r(views),
    c("short", NA, "a string longer than twelve bytes")
  )
})

# From test-write.R.
test_that("nanoarrow reads what arrow_write() writes as a stream", {
  skip_without_oracle("nanoarrow")
  df <- data.frame(x = c(1.5, NA), s = c("a", NA))
  stream <- nanoarrow::read_nanoarrow(arrow_write(df, NULL, format = "stream"))
  expect_identical(as.data.frame(stream), df)
})
