# Oracle 3 (design section 9): handles cross between zuarrow and nanoarrow
# in both directions without conversion.

test_that("zuarrow accepts nanoarrow's schemas, arrays and streams", {
  skip_if_not_installed("nanoarrow")
  schema <- nanoarrow::na_int64()
  expect_identical(format(arrow_schema(schema)), "int64")

  array <- nanoarrow::as_nanoarrow_array(c(1.5, NA, 3))
  expect_identical(format(arrow_schema(array)), "double")
  expect_true(arrow_validate(array))
  expect_true(arrow_equal(array, nanoarrow::as_nanoarrow_array(c(1.5, NA, 3))))

  stream <- nanoarrow::basic_array_stream(list(
    nanoarrow::as_nanoarrow_array(1:3),
    nanoarrow::as_nanoarrow_array(4:6)
  ))
  expect_identical(format(arrow_schema(stream)), "int32")
  expect_true(arrow_validate(stream))
})

test_that("zuarrow reads nanoarrow's schema metadata", {
  skip_if_not_installed("nanoarrow")
  schema <- nanoarrow::nanoarrow_schema_modify(
    nanoarrow::na_int32(),
    list(metadata = list(origin = "nanoarrow"))
  )
  expect_identical(arrow_metadata(schema), c(origin = "nanoarrow"))
})

test_that("nanoarrow accepts zuarrow's schemas, arrays and streams", {
  skip_if_not_installed("nanoarrow")
  schema <- arrow_schema(data.frame(x = 1L, y = "a"))
  parsed <- nanoarrow::nanoarrow_schema_parse(schema)
  expect_identical(parsed$type, "struct")

  array <- test_int32(c(1L, 2L, 3L))
  expect_identical(nanoarrow::convert_array(array), c(1L, 2L, 3L))

  stream <- test_stream("i", list(test_int32(1:2), test_int32(3:4)))
  expect_identical(nanoarrow::convert_array_stream(stream), 1:4)
})

test_that("nanoarrow's coercions return zuarrow handles unchanged", {
  skip_if_not_installed("nanoarrow")
  schema <- arrow_schema("i")
  expect_s3_class(nanoarrow::as_nanoarrow_schema(schema), "zuarrow_schema")
  array <- test_int32(1:3)
  expect_s3_class(nanoarrow::as_nanoarrow_array(array), "zuarrow_array")
  stream <- test_stream("i", list())
  expect_s3_class(
    nanoarrow::as_nanoarrow_array_stream(stream),
    "zuarrow_array_stream"
  )
})

test_that("a zuarrow array equals nanoarrow's array of the same values", {
  skip_if_not_installed("nanoarrow")
  expect_true(arrow_equal(test_int32(1:3), nanoarrow::as_nanoarrow_array(1:3)))
})
