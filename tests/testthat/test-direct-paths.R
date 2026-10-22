# The direct paths read typed buffers in one loop (src/zar_to_r.c); these
# cases check them against values worked out by hand.

test_that("a null slot holding INT_MIN is not an exactness error", {
  # 0x80000000 is INT_MIN, R's NA_integer_; under a null it is no value
  array <- test_array(
    "i",
    3,
    list(as.raw(0x05), le_int(c(1, -2147483648, 3), 4L)),
    null_count = 1
  )
  expect_identical(arrow_to_r(array), c(1L, NA, 3L))
  live <- test_array("i", 1, list(NULL, le_int(-2147483648, 4L)))
  expect_error(arrow_to_r(live), class = "zuarrow_lossy_error")
})

test_that("every integer width and float converts with nulls", {
  validity <- as.raw(0x0b) # rows 1, 2 and 4 are valid
  for (case in list(
    list("c", 1L),
    list("C", 1L),
    list("s", 2L),
    list("S", 2L),
    list("i", 4L)
  )) {
    array <- test_array(
      case[[1]],
      4,
      list(validity, le_int(c(5, 6, 7, 8), case[[2]])),
      null_count = 1
    )
    expect_identical(arrow_to_r(array), c(5L, 6L, NA, 8L), info = case[[1]])
  }
  # uint32 and the 64-bit types become doubles: they can exceed int32
  for (format in c("I", "l", "L")) {
    width <- if (format == "I") 4L else 8L
    array <- test_array(
      format,
      4,
      list(validity, le_int(c(5, 6, 7, 8), width)),
      null_count = 1
    )
    expect_identical(arrow_to_r(array), c(5, 6, NA, 8), info = format)
  }
  floats <- test_array(
    "f",
    4,
    list(
      validity,
      writeBin(c(0.5, 1.5, 2.5, 3.5), raw(), size = 4, endian = "little")
    ),
    null_count = 1
  )
  expect_identical(arrow_to_r(floats), c(0.5, 1.5, NA, 3.5))
})

test_that("bool and arrow.bool8 convert with nulls", {
  bools <- test_array("b", 5, list(as.raw(0x1b), as.raw(0x15)), null_count = 1)
  expect_identical(arrow_to_r(bools), c(TRUE, FALSE, NA, FALSE, TRUE))
})

test_that("sliced arrays convert from their offset", {
  skip_if_not_installed("nanoarrow")
  slice <- function(x, offset, length) {
    nanoarrow::nanoarrow_array_modify(
      nanoarrow::as_nanoarrow_array(x),
      list(offset = offset, length = length)
    )
  }
  expect_identical(
    arrow_to_r(slice(c(1L, NA, 3L, 4L, 5L), 1L, 3L)),
    c(NA, 3L, 4L)
  )
  expect_identical(arrow_to_r(slice(c(0.5, 1.5, NA, 3.5), 2L, 2L)), c(NA, 3.5))
  expect_identical(
    arrow_to_r(slice(c(TRUE, NA, FALSE, TRUE), 1L, 3L)),
    c(NA, FALSE, TRUE)
  )
  expect_identical(
    arrow_to_r(slice(as.Date("2026-10-22") + c(0L, NA, 2L), 1L, 2L)),
    as.Date("2026-10-22") + c(NA, 2L)
  )
  expect_identical(
    arrow_to_r(slice(c("a", NA, "cc", "d"), 1L, 3L)),
    c(NA, "cc", "d")
  )
})

test_that("fields of a struct with nulls are NA in its null rows", {
  df <- data.frame(
    i = c(1L, 2L, 3L),
    d = c(0.5, 1.5, 2.5),
    s = c("a", "b", "c")
  )
  df$day <- as.Date("2026-10-22") + 0:2
  schema <- arrow_schema(data.frame(x = I(df)))
  inner <- test_array_spec(
    3,
    list(as.raw(0x05), NULL),
    null_count = 1,
    children = list(
      test_array_spec(3, list(NULL, le_int(c(1, 2, 3), 4L))),
      test_array_spec(
        3,
        list(NULL, writeBin(c(0.5, 1.5, 2.5), raw(), endian = "little"))
      ),
      test_array_spec(
        3,
        list(NULL, le_int(c(0, 1, 2, 3), 4L), charToRaw("abc"))
      ),
      test_array_spec(3, list(NULL, le_int(20748 + 0:2, 4L)))
    )
  )
  out <- arrow_to_r(test_array(schema, 3, list(NULL), children = list(inner)))$x
  expect_identical(out$i, c(1L, NA, 3L))
  expect_identical(out$d, c(0.5, NA, 2.5))
  expect_identical(out$s, c("a", NA, "c"))
  expect_identical(out$day, as.Date("2026-10-22") + c(0L, NA, 2L))
})

test_that("list columns from R keep NULLs, empty elements and classes", {
  x <- list(1:2, NULL, integer(), 3L)
  expect_identical(arrow_to_r(arrow_array(x)), x)
  dates <- list(as.Date("2026-10-22"), NULL, as.Date("2026-10-23") + 0:1)
  expect_identical(arrow_to_r(arrow_array(dates)), dates)
  expect_error(arrow_array(list(1L, 2.5)), class = "zuarrow_type_error")
})

test_that("numeric columns from R round-trip with NAs", {
  x <- data.frame(
    i = c(1L, NA, 3L),
    d = c(NA, 1.5, NaN),
    l = c(TRUE, NA, FALSE),
    day = as.Date("2026-10-22") + c(0L, NA, 2L)
  )
  out <- arrow_to_r(arrow_array(x))
  expect_identical(out, x)
  expect_true(is.nan(out$d[[3]]))
})

test_that("empty arrays with no buffers convert", {
  for (format in c("i", "l", "L", "c", "f", "g", "b", "tdD", "tsu:UTC", "u")) {
    empty <- test_array(
      format,
      0,
      list(NULL, NULL, NULL)[seq_len(if (format == "u") 3 else 2)]
    )
    expect_length(arrow_to_r(empty, lossy = "allow"), 0L)
  }
})
