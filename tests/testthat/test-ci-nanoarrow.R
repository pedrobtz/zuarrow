# Interchange with the nanoarrow R package (design section 9). nanoarrow is
# not a dependency: this file is left out of the package tarball
# (.Rbuildignore) and runs from the source tree, in CI by oracles.yaml.

# From test-dictionary.R.
test_that("nanoarrow's dictionaries read as factors", {
  skip_without_oracle("nanoarrow")
  f <- factor(c("x", "y", "x"))
  expect_identical(arrow_to_r(nanoarrow::as_nanoarrow_array(f)), f)
})

# From test-read.R.
test_that("a lazy stream crosses to nanoarrow", {
  skip_without_oracle("nanoarrow")
  stream <- arrow_read(test_data("basic.arrows"), lazy = TRUE)
  out <- as.data.frame(nanoarrow::as_nanoarrow_array_stream(stream))
  expect_identical(out$i, basic_df()$i)
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

# From test-read-rules.R (#207).
test_that("a failed reader stays failed through the C stream's get_next()", {
  skip_without_oracle("nanoarrow")
  bytes <- arrow_write(
    data.frame(n = 1:6, s = letters[1:6]),
    NULL,
    format = "file",
    batch = 2
  )
  m <- ipc_messages(bytes, 8)
  body <- m[[3]]$start + m[[3]]$meta + 8
  bytes[body + 5:8] <- as.raw(c(0xff, 0xff, 0xff, 0x7f))
  s <- arrow_read(bytes, lazy = TRUE)
  expect_identical(arrow_to_r(s$get_next())$n, 1:2)
  first <- tryCatch(s$get_next(), error = identity)
  expect_s3_class(first, "error")
  for (k in 1:2) {
    later <- tryCatch(s$get_next(), error = identity)
    expect_s3_class(later, "error")
    expect_identical(conditionMessage(later), conditionMessage(first))
  }
})
