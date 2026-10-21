test_that("arrow_stream() batches a data frame", {
  df <- data.frame(x = 1:5, y = letters[1:5])
  stream <- arrow_stream(df, batch = 2)
  expect_s3_class(stream, "zuarrow_array_stream")
  expect_identical(arrow_next(stream), df[1:2, ])
  rest <- arrow_next(stream)
  expect_identical(nrow(rest), 2L)
  expect_identical(rest$x, 3:4)
  expect_identical(arrow_next(stream)$x, 5L)
  expect_null(arrow_next(stream))
  expect_null(arrow_next(stream))
})

test_that("as.data.frame() reads a stream to its end", {
  df <- data.frame(x = c(1.5, NA, 3), d = as.Date("2026-10-21") + 0:2)
  expect_identical(as.data.frame(arrow_stream(df, batch = 2)), df)
  expect_identical(as.data.frame(arrow_array(df)), df)
})

test_that("an empty data frame gives a stream with no batches", {
  df <- data.frame(x = integer(), y = character())
  stream <- arrow_stream(df)
  expect_identical(format(arrow_schema(stream)), "struct<x: int32, y: string>")
  out <- as.data.frame(stream)
  expect_identical(out, df)
})

test_that("as.data.frame() takes the same lossy default", {
  schema <- arrow_schema(data.frame(n = 1L))
  spec <- .Call(zuarrow:::zar_c_schema_to_spec, schema)
  spec$children[[1]]$format <- "l"
  big_schema <- test_schema(spec)
  batch <- test_array(
    big_schema,
    1,
    list(NULL),
    children = list(test_array_spec(1, list(NULL, le_hex("0020000000000001"))))
  )
  stream <- test_stream(big_schema, list(batch))
  expect_error(as.data.frame(stream), class = "zuarrow_lossy_error")
})

test_that("as.vector() converts an array", {
  expect_identical(as.vector(arrow_array(c(1L, NA))), c(1L, NA))
})

test_that("a stream that is not of struct reads as one vector", {
  stream <- test_stream("i", list(test_int32(1:2), test_int32(3L)))
  expect_identical(arrow_to_r(stream), 1:3)
  stream <- test_stream("i", list(test_int32(1:2)))
  expect_error(as.data.frame(stream), class = "zuarrow_type_error")
})

test_that("batch must be a positive whole number", {
  expect_error(
    arrow_stream(data.frame(x = 1), batch = 0),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_stream(data.frame(x = 1), batch = 1.5),
    class = "zuarrow_type_error"
  )
})

test_that("a nanoarrow stream converts through zuarrow", {
  skip_if_not_installed("nanoarrow")
  df <- data.frame(x = 1:3, y = c("a", "b", NA))
  stream <- nanoarrow::as_nanoarrow_array_stream(df)
  expect_identical(arrow_to_r(stream), df)
})

test_that("nanoarrow reads what arrow_stream() writes", {
  skip_if_not_installed("nanoarrow")
  df <- data.frame(x = c(1.5, NA), y = c("a", NA), b = c(TRUE, FALSE))
  expect_identical(
    as.data.frame(nanoarrow::convert_array_stream(arrow_stream(df))),
    df
  )
})
