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

test_that("arrays compare value by value, ignoring bytes under nulls", {
  validity <- as.raw(0x05) # rows 1 and 3 valid, row 2 null
  x <- test_array(
    "i",
    3,
    list(validity, writeBin(c(1L, 7L, 3L), raw(), endian = "little")),
    null_count = 1
  )
  y <- test_array(
    "i",
    3,
    list(validity, writeBin(c(1L, 9L, 3L), raw(), endian = "little")),
    null_count = 1
  )
  expect_true(arrow_equal(x, y))

  # A null against a value is a difference.
  z <- test_int32(c(1L, 7L, 3L))
  expect_false(arrow_equal(x, z))
})

test_that("arrays with different offsets but equal values are equal", {
  x <- test_array(
    "i",
    2,
    list(NULL, writeBin(c(0L, 5L, 6L), raw(), endian = "little")),
    offset = 1
  )
  expect_true(arrow_equal(x, test_int32(5:6)))
  expect_false(arrow_equal(x, test_int32(c(5L, 7L))))
})

test_that("strings under a null slot do not count", {
  validity <- as.raw(0x01)
  x <- test_array(
    "u",
    2,
    list(
      validity,
      writeBin(c(0L, 1L, 3L), raw(), endian = "little"),
      charToRaw("abc")
    ),
    null_count = 1
  )
  y <- test_array(
    "u",
    2,
    list(
      validity,
      writeBin(c(0L, 1L, 1L), raw(), endian = "little"),
      charToRaw("a")
    ),
    null_count = 1
  )
  expect_true(arrow_equal(x, y))
  expect_false(arrow_equal(x, test_utf8(c(0L, 1L, 3L), charToRaw("abc"))))
})

test_that("nested values under a null struct row do not count", {
  schema <- test_schema(zspec("+s", children = list(zspec("i", "a"))))
  make <- function(values, validity = as.raw(0x05), null_count = 1) {
    test_array(
      schema,
      3,
      list(validity),
      null_count = null_count,
      children = list(test_array_spec(
        3,
        list(NULL, writeBin(values, raw(), endian = "little"))
      ))
    )
  }
  expect_true(arrow_equal(make(c(1L, 2L, 3L)), make(c(1L, 9L, 3L))))
  expect_false(arrow_equal(make(c(1L, 2L, 3L)), make(c(1L, 2L, 4L))))
  expect_false(arrow_equal(
    make(c(1L, 2L, 3L)),
    make(c(1L, 2L, 3L), as.raw(0x07), 0)
  ))
  expect_true(arrow_equal(
    arrow_array(list(1:2, NULL, 3L)),
    arrow_array(list(1:2, NULL, 3L))
  ))
  expect_false(arrow_equal(
    arrow_array(list(1:2, 3L)),
    arrow_array(list(1L, 2:3))
  ))
  expect_true(arrow_equal(
    arrow_array(factor(c("b", "a"))),
    arrow_array(factor(c("b", "a")))
  ))
  expect_false(arrow_equal(
    arrow_array(factor(c("b", "a"))),
    arrow_array(factor(c("a", "b"), levels = c("b", "a")))
  ))
})
