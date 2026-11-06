# A condition names the exported function or S3 method the user called,
# never an internal helper (#124, design section 8).

test_that("arrow_array() and arrow_stream() errors name the function", {
  expect_identical(
    caught_call(arrow_array(300L, schema = "c"))[[1L]],
    quote(arrow_array)
  )
  expect_identical(
    caught_call(arrow_stream(300L, schema = "c"))[[1L]],
    quote(arrow_stream)
  )
})

test_that("arrow_to_r() conversion errors name arrow_to_r()", {
  schema <- test_schema(zspec("+s", children = list(zspec("l", "x"))))
  array <- arrow_array(2^53 + 2, schema = "l")
  expect_identical(caught_call(arrow_to_r(array))[[1L]], quote(arrow_to_r))

  stream <- arrow_stream(data.frame(x = 2^53 + 2), schema = schema)
  expect_identical(caught_call(arrow_to_r(stream))[[1L]], quote(arrow_to_r))
})

test_that("arrow_read() conversion errors name arrow_read()", {
  schema <- test_schema(zspec("+s", children = list(zspec("l", "x"))))
  stream <- arrow_stream(data.frame(x = 2^53 + 2), schema = schema)
  bytes <- arrow_write(stream, NULL)
  expect_identical(caught_call(arrow_read(bytes))[[1L]], quote(arrow_read))
})

test_that("arrow_write() errors name arrow_write()", {
  df <- data.frame(x = I(list(1, "a")))
  expect_identical(caught_call(arrow_write(df, NULL))[[1L]], quote(arrow_write))
})

test_that("the as.data.frame() methods name themselves", {
  schema <- test_schema(zspec("+s", children = list(zspec("l", "x"))))
  array <- arrow_array(data.frame(x = 2^53 + 2), schema = schema)
  expect_identical(
    caught_call(as.data.frame(array))[[1L]],
    quote(as.data.frame.zuarrow_array)
  )

  stream <- arrow_stream(data.frame(x = 2^53 + 2), schema = schema)
  expect_identical(
    caught_call(as.data.frame(stream))[[1L]],
    quote(as.data.frame.zuarrow_array_stream)
  )

  expect_identical(
    caught_call(as.data.frame(arrow_array(1:3)))[[1L]],
    quote(as.data.frame.zuarrow_array)
  )
})

test_that("the as.vector() method names itself", {
  array <- arrow_array(2^53 + 2, schema = "l")
  expect_identical(
    caught_call(as.vector(array))[[1L]],
    quote(as.vector.zuarrow_array)
  )
})

test_that("a released handle's error names the exported function", {
  stream <- arrow_stream(data.frame(x = 1:3))
  test_release(stream)
  expect_identical(caught_call(arrow_to_r(stream))[[1L]], quote(arrow_to_r))

  array <- arrow_array(1:3)
  test_release(array)
  expect_identical(
    caught_call(arrow_validate(array))[[1L]],
    quote(arrow_validate)
  )
})
