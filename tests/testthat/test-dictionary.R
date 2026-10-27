# Dictionaries, design section 6.5.

test_that("a factor round-trips as dictionary<int32, utf8>", {
  f <- factor(c("b", NA, "a", "b"), levels = c("b", "a", "unused"))
  array <- arrow_array(f)
  expect_match(format(arrow_schema(array)), "dictionary\\(int32\\)<string>")
  expect_identical(arrow_to_r(array), f)
  expect_true(arrow_validate(array, "full"))
})

test_that("an ordered factor keeps its order through the flag", {
  f <- factor(c("lo", "hi"), levels = c("lo", "hi"), ordered = TRUE)
  expect_identical(arrow_to_r(arrow_array(f)), f)
})

test_that("factor columns round-trip through a stream", {
  df <- data.frame(f = factor(c("x", "y", NA, "x")), n = 1:4)
  expect_identical(as.data.frame(arrow_stream(df, batch = 2)), df)
})

test_that("batches with different dictionaries read as the union of levels", {
  schema <- arrow_schema(factor("a"))
  batch <- function(codes, levels) {
    test_array(
      schema,
      length(codes),
      list(NULL, le_int(codes, 4L)),
      dictionary = test_array_spec(
        length(levels),
        list(
          NULL,
          le_int(c(0, cumsum(nchar(levels))), 4L),
          charToRaw(paste(levels, collapse = ""))
        )
      )
    )
  }
  stream <- test_stream(
    schema,
    list(batch(c(0, 1), c("a", "b")), batch(c(1, 0), c("a", "c")))
  )
  out <- arrow_to_r(stream)
  expect_identical(
    out,
    factor(c("a", "b", "c", "a"), levels = c("a", "b", "c"))
  )
})

test_that("a dictionary of other values decodes to their R form", {
  schema <- test_schema(list(
    format = "c",
    name = "",
    flags = 2L,
    metadata = NULL,
    children = list(),
    dictionary = zspec("g")
  ))
  array <- test_array(
    schema,
    3,
    list(as.raw(0x05), le_int(c(1, 0, 0), 1L)),
    null_count = 1,
    dictionary = test_array_spec(
      2,
      list(NULL, writeBin(c(0.5, 9), raw(), endian = "little"))
    )
  )
  expect_identical(arrow_to_r(array), c(9, NA, 0.5))
})

test_that("a dictionary with a null value decodes to character", {
  schema <- arrow_schema(factor("a"))
  array <- test_array(
    schema,
    2,
    list(NULL, le_int(c(0, 1), 4L)),
    dictionary = test_array_spec(
      2,
      list(as.raw(0x01), le_int(c(0, 1, 1), 4L), charToRaw("a")),
      null_count = 1
    )
  )
  expect_identical(arrow_to_r(array), c("a", NA))
})

test_that("factors can be written as plain strings", {
  f <- factor(c("b", NA, "a"))
  expect_identical(arrow_to_r(arrow_array(f, schema = "u")), c("b", NA, "a"))
})

test_that("an index out of range is a format error", {
  schema <- arrow_schema(factor("a"))
  array <- test_array(
    schema,
    1,
    list(NULL, le_int(5, 4L)),
    dictionary = test_array_spec(
      1,
      list(NULL, le_int(c(0, 1), 4L), charToRaw("a"))
    )
  )
  expect_error(arrow_to_r(array), class = "zuarrow_format_error")
})

test_that("nanoarrow's dictionaries read as factors", {
  skip_if_not_installed("nanoarrow")
  f <- factor(c("x", "y", "x"))
  expect_identical(arrow_to_r(nanoarrow::as_nanoarrow_array(f)), f)
})

test_that("a level with an embedded NUL is cut there under warn and allow", {
  schema <- arrow_schema(factor("a"))
  array <- test_array(
    schema,
    3,
    list(NULL, le_int(c(0, 1, 2), 4L)),
    dictionary = test_array_spec(
      3,
      list(
        NULL,
        le_int(c(0, 1, 4, 5), 4L),
        c(charToRaw("a"), as.raw(c(0x61, 0x00, 0x62)), charToRaw("c"))
      )
    )
  )
  err <- expect_error(arrow_to_r(array), class = "zuarrow_lossy_error")
  expect_identical(err$arrow_type, "i")
  expect_identical(
    arrow_to_r(array, lossy = "allow"),
    factor(c("a", "a", "c"), levels = c("a", "c"))
  )
  expect_warning(
    out <- arrow_to_r(array, lossy = "warn"),
    class = "zuarrow_lossy_warning"
  )
  expect_identical(out, factor(c("a", "a", "c"), levels = c("a", "c")))
})

test_that("a non-string dictionary index out of range is a format error", {
  schema <- test_schema(list(
    format = "i",
    name = "",
    flags = 2L,
    metadata = NULL,
    children = list(),
    dictionary = zspec("g")
  ))
  array <- test_array(
    schema,
    2,
    list(NULL, le_int(c(0, 100000), 4L)),
    dictionary = test_array_spec(
      1,
      list(NULL, writeBin(1.5, raw(), endian = "little"))
    )
  )
  expect_error(arrow_to_r(array), class = "zuarrow_format_error")
  negative <- test_array(
    schema,
    1,
    list(NULL, le_int(-1, 4L)),
    dictionary = test_array_spec(
      1,
      list(NULL, writeBin(1.5, raw(), endian = "little"))
    )
  )
  expect_error(arrow_to_r(negative), class = "zuarrow_format_error")
})
