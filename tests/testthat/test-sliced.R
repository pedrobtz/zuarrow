# Arrays with a nonzero offset, built from raw buffers so the shipped suite
# reaches every offset path without nanoarrow (#105). Each validity offset
# is not a multiple of 8, so a bitmap read from the wrong bit is caught.

test_that("a sliced int32 array converts from its offset", {
  valid <- c(TRUE, TRUE, TRUE, TRUE, FALSE, TRUE, TRUE, TRUE, TRUE, FALSE)
  array <- test_array(
    "i",
    5,
    list(test_bits(valid), le_int(0:9, 4L)),
    null_count = 1,
    offset = 3
  )
  expect_true(arrow_validate(array, "full"))
  expect_identical(arrow_to_r(array), c(3L, NA, 5L, 6L, 7L))
})

test_that("a sliced int32 array without nulls converts from its offset", {
  array <- test_array("i", 4, list(NULL, le_int(0:9, 4L)), offset = 5)
  expect_identical(arrow_to_r(array), 5:8)
})

test_that("a sliced double array converts from its offset", {
  valid <- c(TRUE, TRUE, TRUE, FALSE, TRUE, TRUE, TRUE)
  values <- c(0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5)
  array <- test_array(
    "g",
    3,
    list(test_bits(valid), writeBin(values, raw(), endian = "little")),
    null_count = 1,
    offset = 2
  )
  expect_true(arrow_validate(array, "full"))
  expect_identical(arrow_to_r(array), c(2.5, NA, 4.5))
})

test_that("a sliced boolean array reads values and validity from its bit", {
  values <- rep(c(TRUE, FALSE, FALSE), length.out = 20)
  valid <- rep(TRUE, 20)
  valid[c(13, 17)] <- FALSE
  array <- test_array(
    "b",
    7,
    list(test_bits(valid), test_bits(values)),
    null_count = 2,
    offset = 11
  )
  expected <- values[12:18]
  expected[c(2, 6)] <- NA
  expect_true(arrow_validate(array, "full"))
  expect_identical(arrow_to_r(array), expected)
})

test_that("a sliced date32 array converts from its offset", {
  valid <- c(TRUE, TRUE, FALSE, TRUE, TRUE)
  array <- test_array(
    "tdD",
    3,
    list(test_bits(valid), le_int(20000 + 0:4, 4L)),
    null_count = 1,
    offset = 1
  )
  expect_identical(
    arrow_to_r(array),
    as.Date(c(20001, NA, 20003))
  )
})

test_that("a sliced string array reads its offsets from its offset", {
  x <- c("a", "bb", NA, "", "dddd", "e")
  valid <- !is.na(x)
  for (format in c("u", "U")) {
    array <- test_array(
      format,
      4,
      c(list(test_bits(valid)), test_string_buffers(x, large = format == "U")),
      null_count = 1,
      offset = 1
    )
    expect_true(arrow_validate(array, "full"), info = format)
    expect_identical(arrow_to_r(array), x[2:5], info = format)
  }
})

test_that("a sliced string array is deferred and reads from its offset", {
  x <- c("a", "bb", NA, "ccc", "", "dddd", NA, "e", "ff")
  valid <- !is.na(x)
  for (format in c("u", "U")) {
    array <- test_array(
      format,
      6,
      c(list(test_bits(valid)), test_string_buffers(x, large = format == "U")),
      null_count = 2,
      offset = 2
    )
    out <- arrow_to_r(array, copy = FALSE)
    expect_false(is.null(deferred_info(out)), info = format)
    expect_identical(out[[1]], NA_character_, info = format)
    expect_identical(out[[4]], "dddd", info = format)
    expect_identical(out, x[3:8], info = format)
  }
})

test_that("a struct with an offset reads its children from that offset", {
  schema <- arrow_schema(data.frame(x = 1L, y = "a"))
  y <- c("p", "q", "r", "s")
  array <- test_array(
    schema,
    2,
    list(NULL),
    offset = 2,
    children = list(
      # The child has its own offset, added to the struct's.
      test_array_spec(4, list(NULL, le_int(10:14, 4L)), offset = 1),
      test_array_spec(4, c(list(NULL), test_string_buffers(y)))
    )
  )
  expect_true(arrow_validate(array, "full"))
  expect_identical(arrow_to_r(array), data.frame(x = 13:14, y = c("r", "s")))
})

test_that("a struct's validity is read from its offset", {
  schema <- arrow_schema(data.frame(x = 1L))
  array <- test_array(
    schema,
    3,
    list(test_bits(c(TRUE, TRUE, TRUE, FALSE, TRUE))),
    null_count = 1,
    offset = 2,
    children = list(test_array_spec(5, list(NULL, le_int(0:4, 4L))))
  )
  expect_identical(arrow_to_r(array), data.frame(x = c(2L, NA, 4L)))
})

test_that("a handler sees a sliced field", {
  local_registration("i", to = function(array, schema) arrow_to_r(array) * 10L)
  schema <- arrow_schema(data.frame(a = 1L))
  array <- test_array(
    schema,
    2,
    list(NULL),
    offset = 1,
    children = list(test_array_spec(4, list(NULL, le_int(1:4, 4L))))
  )
  expect_identical(arrow_to_r(array)$a, c(20L, 30L))
})
