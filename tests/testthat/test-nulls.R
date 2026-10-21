# Nulls, design section 6.9.

test_that("every NA becomes a null over a zeroed slot", {
  expect_true(arrow_equal(
    arrow_array(c(7L, NA)),
    test_array("i", 2, list(as.raw(0x01), le_int(c(7, 0), 4L)), null_count = 1)
  ))
  expect_true(arrow_equal(
    arrow_array(c(NA, 2.5)),
    test_array(
      "g",
      2,
      list(as.raw(0x02), writeBin(c(0, 2.5), raw(), endian = "little")),
      null_count = 1
    )
  ))
  expect_true(arrow_equal(
    arrow_array(c("ab", NA)),
    test_array(
      "u",
      2,
      list(as.raw(0x01), le_int(c(0, 2, 2), 4L), charToRaw("ab")),
      null_count = 1
    )
  ))
  expect_true(arrow_equal(
    arrow_array(c(TRUE, NA)),
    test_array("b", 2, list(as.raw(0x01), as.raw(0x01)), null_count = 1)
  ))
})

test_that("NaN stays a value and NA a null", {
  array <- arrow_array(c(NaN, NA))
  out <- arrow_to_r(array)
  expect_true(is.nan(out[[1]]))
  expect_true(is.na(out[[2]]) && !is.nan(out[[2]]))
})

test_that("a double whose bits are R's NA reads as NA", {
  bits <- test_array(
    "g",
    1,
    list(NULL, writeBin(NA_real_, raw(), endian = "little"))
  )
  out <- arrow_to_r(bits)
  expect_true(is.na(out) && !is.nan(out))
})

test_that("the string NA is a value, NA_character_ a null", {
  out <- arrow_to_r(arrow_array(c("NA", NA)))
  expect_identical(out, c("NA", NA))
})

test_that("a null struct row is NA in every column", {
  schema <- arrow_schema(data.frame(x = 1L, y = "a"))
  array <- test_array(
    schema,
    length = 2,
    null_count = 1,
    buffers = list(as.raw(0x01)),
    children = list(
      test_array_spec(2, list(NULL, le_int(c(1, 2), 4L))),
      test_array_spec(2, list(NULL, le_int(c(0, 1, 2), 4L), charToRaw("ab")))
    )
  )
  out <- arrow_to_r(array)
  expect_identical(out, data.frame(x = c(1L, NA), y = c("a", NA)))
})

test_that("a struct with an offset reads its children from that offset", {
  skip_if_not_installed("nanoarrow")
  array <- nanoarrow::as_nanoarrow_array(data.frame(x = 1:4, y = letters[1:4]))
  sliced <- nanoarrow::nanoarrow_array_modify(
    array,
    list(offset = 2, length = 2)
  )
  expect_identical(arrow_to_r(sliced), data.frame(x = 3:4, y = c("c", "d")))
})
