test_that("schemas compare by format, name, flags and children", {
  expect_true(arrow_equal(arrow_schema("i"), arrow_schema("i")))
  expect_false(arrow_equal(arrow_schema("i"), arrow_schema("l")))
  expect_false(arrow_equal(
    arrow_schema(data.frame(x = 1L)),
    arrow_schema(data.frame(y = 1L))
  ))
  expect_false(arrow_equal(
    arrow_schema(data.frame(x = 1L)),
    arrow_schema(data.frame(x = 1L, y = 1L))
  ))
  expect_false(arrow_equal(
    arrow_schema(factor("a")),
    arrow_schema(factor("a", ordered = TRUE))
  ))
})

test_that("a difference carries a reason", {
  result <- arrow_equal(arrow_schema("i"), arrow_schema("l"))
  expect_type(attr(result, "reason"), "character")
  expect_null(attr(arrow_equal(arrow_schema("i"), arrow_schema("i")), "reason"))
})

test_that("the reason is not set on R's shared FALSE", {
  result <- arrow_equal(arrow_schema("i"), arrow_schema("l"))
  expect_false(result)
  expect_null(attributes(!TRUE))
  expect_null(attributes(identical(1, 2)))
})

test_that("metadata counts unless metadata = FALSE", {
  x <- arrow_schema("i")
  y <- x
  arrow_metadata(y) <- c(a = "1")
  expect_false(arrow_equal(x, y))
  expect_true(arrow_equal(x, y, metadata = FALSE))
  expect_error(arrow_equal(x, y, metadata = NA), class = "zuarrow_type_error")
})

test_that("arrays compare by schema and buffers", {
  expect_true(arrow_equal(test_int32(1:3), test_int32(1:3)))
  expect_false(arrow_equal(test_int32(1:3), test_int32(c(1L, 2L, 4L))))
  expect_false(arrow_equal(test_int32(1:3), test_int32(1:4)))
  expect_false(arrow_equal(
    test_int32(1:2),
    test_array("I", 2, list(NULL, writeBin(1:2, raw(), endian = "little")))
  ))
})

test_that("a malformed array is a format error, not a difference", {
  bad <- test_utf8(c(-1L, 1L), charToRaw("abc"))
  good <- test_utf8(c(0L, 1L), charToRaw("abc"))
  expect_error(arrow_equal(bad, good), class = "zuarrow_format_error")
})

test_that("streams compare batch by batch", {
  make <- function(...) test_stream("i", lapply(list(...), test_int32))
  expect_true(arrow_equal(make(1:2, 3:4), make(1:2, 3:4)))
  expect_false(arrow_equal(make(1:2, 3:4), make(1:2, 3:5)))
  expect_false(arrow_equal(make(1:2, 3:4), make(1:2)))
})

test_that("handles of different kinds are a handle error", {
  expect_error(
    arrow_equal(arrow_schema("i"), test_int32(1L)),
    class = "zuarrow_handle_error"
  )
  expect_error(arrow_equal(1, 1), class = "zuarrow_handle_error")
})
