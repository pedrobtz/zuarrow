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

# From test-registry.R (#189, #204).
test_that("arrow_stream() moved out to nanoarrow outlives every R reference", {
  skip_without_oracle("nanoarrow")
  local_registration(
    "g",
    from = function(x) arrow_array(as.double(unclass(x))),
    class = "fake_dbl"
  )
  n <- 5000L
  expected <- data.frame(id = seq_len(n), v = as.double(seq_len(n)) * 10)
  make_df <- function(registered) {
    df <- expected
    if (registered) {
      df$v <- structure(df$v, class = "fake_dbl")
    }
    df
  }
  for (registered in c(FALSE, TRUE)) {
    for (batch in c(n, 1000L)) {
      dst <- nanoarrow::nanoarrow_allocate_array_stream()
      local({
        stream <- arrow_stream(make_df(registered), batch = batch)
        nanoarrow::nanoarrow_pointer_move(stream, dst)
      })
      heap_churn()
      out <- as.data.frame(nanoarrow::convert_array_stream(dst))
      expect_identical(out, expected, info = paste(registered, batch))

      # A batch nanoarrow takes holds nothing of the stream's in R.
      first <- local({
        stream <- arrow_stream(make_df(registered), batch = batch)
        stream$get_next()
      })
      heap_churn()
      out <- as.data.frame(nanoarrow::convert_array(first))
      expect_identical(out, expected[seq_len(batch), ], info = batch)
    }
  }
})

# From test-handles.R (#204).
test_that("a borrowed string view is a copy that outlives its source", {
  skip_without_oracle("nanoarrow")
  v <- c("short", NA, "a string longer than twelve bytes")
  source <- nanoarrow::as_nanoarrow_array(
    v,
    schema = nanoarrow::na_string_view()
  )
  copy <- zuarrow:::zar_check(.Call(zuarrow:::zar_c_array_borrow, source))
  nanoarrow::nanoarrow_pointer_release(source)
  heap_churn(n = 5L)
  expect_identical(arrow_to_r(copy), v)
})
