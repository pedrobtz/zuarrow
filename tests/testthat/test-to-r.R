# Arrow to R, the built-in table of design section 6.2.

test_that("null converts to a logical of NA", {
  expect_identical(
    arrow_to_r(test_array("n", 3, list(), null_count = 3)),
    rep(NA, 3)
  )
})

test_that("bool and the small integers convert exactly", {
  expect_identical(
    arrow_to_r(arrow_array(c(TRUE, NA, FALSE))),
    c(TRUE, NA, FALSE)
  )
  expect_identical(
    arrow_to_r(test_fixed("c", c(-128, 0, 127), 1L)),
    c(-128L, 0L, 127L)
  )
  expect_identical(
    arrow_to_r(test_fixed("s", c(-32768, 32767), 2L)),
    c(-32768L, 32767L)
  )
  expect_identical(arrow_to_r(test_fixed("C", c(0, 255), 1L)), c(0L, 255L))
  expect_identical(arrow_to_r(test_fixed("S", c(0, 65535), 2L)), c(0L, 65535L))
  expect_identical(
    arrow_to_r(test_int32(c(-1L, 2147483647L))),
    c(-1L, 2147483647L)
  )
})

test_that("uint32 converts to double, exactly", {
  expect_identical(
    arrow_to_r(test_fixed("I", c(0, 4294967295), 4L)),
    c(0, 4294967295)
  )
})

test_that("half floats widen exactly, subnormals included", {
  halves <- c(0x3c00, 0xc000, 0x0001, 0x03ff, 0x7bff, 0x7c00, 0xfc00, 0x0000)
  out <- arrow_to_r(test_fixed("e", halves, 2L))
  expect_identical(out, c(1, -2, 2^-24, 1023 * 2^-24, 65504, Inf, -Inf, 0))
  expect_true(is.nan(arrow_to_r(test_fixed("e", 0x7e00, 2L))))
})

test_that("float widens and double copies", {
  f <- test_array(
    "f",
    2,
    list(NULL, writeBin(c(1.5, -0.25), raw(), size = 4, endian = "little"))
  )
  expect_identical(arrow_to_r(f), c(1.5, -0.25))
  expect_identical(
    arrow_to_r(arrow_array(c(0.1, -1e300, NA))),
    c(0.1, -1e300, NA)
  )
})

test_that("int64 and uint64 within 2^53 convert to double", {
  expect_identical(
    arrow_to_r(test_fixed("l", c(-2^53, 0, 2^53), 8L)),
    c(-2^53, 0, 2^53)
  )
  expect_identical(arrow_to_r(test_fixed("L", c(0, 2^53), 8L)), c(0, 2^53))
})

test_that("strings convert in every layout", {
  expect_identical(
    arrow_to_r(arrow_array(c("a", NA, "café"))),
    c("a", NA, "café")
  )
  large <- test_array("U", 2, list(NULL, le_int(c(0, 1, 3)), charToRaw("abc")))
  expect_identical(arrow_to_r(large), c("a", "bc"))
})

test_that("string and binary views convert", {
  skip_if_not_installed("nanoarrow")
  views <- nanoarrow::as_nanoarrow_array(
    c("short", NA, "a string longer than twelve bytes"),
    schema = nanoarrow::na_string_view()
  )
  expect_identical(
    arrow_to_r(views),
    c("short", NA, "a string longer than twelve bytes")
  )
})

test_that("invalid UTF-8 in a string column is a format error", {
  expect_error(
    arrow_to_r(test_utf8(c(0L, 2L), as.raw(c(0xc3, 0x28)))),
    class = "zuarrow_format_error"
  )
})

test_that("binary converts to a list of raw, fixed_size_binary keeps its width", {
  blob <- test_array(
    "z",
    3,
    list(as.raw(0x05), le_int(c(0, 2, 2, 3), 4L), as.raw(c(1, 2, 3))),
    null_count = 1
  )
  expect_identical(arrow_to_r(blob), list(as.raw(c(1, 2)), NULL, as.raw(3)))

  fixed <- test_array("w:2", 2, list(NULL, as.raw(1:4)))
  out <- arrow_to_r(fixed)
  expect_identical(unclass(out)[1:2], list(as.raw(1:2), as.raw(3:4)))
  expect_identical(attr(out, "arrow_width"), 2L)
})

test_that("date32 converts to Date", {
  dates <- as.Date(c("1969-12-31", "2026-10-21", NA))
  expect_identical(arrow_to_r(arrow_array(dates)), dates)
})

test_that("second and millisecond timestamps convert to POSIXct", {
  out <- arrow_to_r(test_fixed("tss:UTC", c(0, 1761040800), 8L))
  expect_s3_class(out, "POSIXct")
  expect_identical(attr(out, "tzone"), "UTC")
  expect_identical(as.numeric(out), c(0, 1761040800))

  ms <- arrow_to_r(test_fixed("tsm:Europe/Lisbon", 1500, 8L))
  expect_identical(as.numeric(ms), 1.5)
  expect_identical(attr(ms, "tzone"), "Europe/Lisbon")

  naive <- arrow_to_r(test_fixed("tss:", 0, 8L))
  expect_identical(attr(naive, "tzone"), "")
})

test_that("a struct converts to a data frame with its field names", {
  df <- data.frame(x = 1:2, y = c("a", "b"))
  out <- arrow_to_r(arrow_array(df))
  expect_identical(out, df)
})

test_that("schema metadata becomes the frame's arrow_metadata attribute", {
  schema <- arrow_schema(data.frame(x = 1L))
  arrow_metadata(schema) <- c(origin = "test")
  out <- arrow_to_r(arrow_array(data.frame(x = 1L), schema = schema))
  expect_identical(attr(out, "arrow_metadata"), c(origin = "test"))
})

test_that("conversion does not accept a non-handle", {
  expect_error(arrow_to_r(1:3), class = "zuarrow_handle_error")
  expect_error(arrow_next(1:3), class = "zuarrow_handle_error")
})
