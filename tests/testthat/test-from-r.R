# R to Arrow, the export half of design section 6.2.

test_that("each R class maps to its Arrow type", {
  type <- function(x) format(arrow_schema(arrow_array(x)))
  expect_identical(type(c(TRUE, NA)), "bool")
  expect_identical(type(1:2), "int32")
  expect_identical(type(c(1.5, 2)), "double")
  expect_identical(type("a"), "string")
  expect_identical(type(as.Date("2026-10-21")), "date32")
  expect_match(
    type(as.POSIXct("2026-10-21", tz = "UTC")),
    "timestamp\\('us', 'UTC'\\)"
  )
  expect_match(type(as.POSIXct("2026-10-21")), "timestamp\\('us', 'UTC'\\)")
  expect_match(type(as.difftime(1, units = "mins")), "duration\\('us'\\)")
  expect_identical(type(list(as.raw(1), NULL)), "binary")
  expect_identical(type(data.frame(x = 1L)), "struct<x: int32>")
})

test_that("an all-NA logical stays bool", {
  expect_identical(format(arrow_schema(arrow_array(c(NA, NA)))), "bool")
})

test_that("a class with no Arrow type is a type error", {
  expect_error(arrow_array(1i), class = "zuarrow_type_error")
  expect_error(arrow_array(as.raw(1:3)), class = "zuarrow_type_error")
  expect_error(
    arrow_array(structure(1, class = "my_class")),
    class = "zuarrow_type_error"
  )
})

test_that("a schema writes the values as its type, checked", {
  expect_identical(
    arrow_to_r(arrow_array(c(1L, -3L), schema = "c")),
    c(1L, -3L)
  )
  expect_error(arrow_array(300L, schema = "c"), class = "zuarrow_lossy_error")
  expect_error(arrow_array(-1L, schema = "C"), class = "zuarrow_lossy_error")
  expect_identical(
    arrow_to_r(arrow_array(c(1, 2^53), schema = "l")),
    c(1, 2^53)
  )
  expect_error(arrow_array(1.5, schema = "l"), class = "zuarrow_lossy_error")
  expect_error(arrow_array(NaN, schema = "l"), class = "zuarrow_lossy_error")
  expect_identical(arrow_to_r(arrow_array(1.5, schema = "f")), 1.5)
  expect_error(arrow_array(0.1, schema = "f"), class = "zuarrow_lossy_error")
  expect_error(arrow_array("a", schema = "i"), class = "zuarrow_type_error")
  expect_error(arrow_array(TRUE, schema = "i"), class = "zuarrow_type_error")
})

test_that("a given schema handle is left as it was", {
  withr::local_options(zuarrow.utf8_limit = 5)
  s <- arrow_schema("u")
  before <- attributes(s)
  arrow_array(1L, schema = arrow_schema("i"))
  arrow_array(c("abc", "def"), schema = s)
  arrow_stream(data.frame(x = 1L), schema = arrow_schema(data.frame(x = 1L)))
  expect_identical(attributes(s), before)
  # A schema made without one still switches to large_utf8.
  expect_identical(
    format(arrow_schema(arrow_array(c("abc", "def")))),
    "large_string"
  )
})

test_that("the lossy error from export names the row", {
  err <- tryCatch(
    arrow_array(c(1L, 200L, 300L), schema = "c"),
    zuarrow_lossy_error = function(e) e
  )
  expect_identical(err$row, 2)
})

test_that("POSIXct exports as microseconds in its zone", {
  x <- as.POSIXct("2026-10-21 10:00:00.25", tz = "Europe/Lisbon")
  out <- arrow_to_r(arrow_array(x), lossy = "allow")
  expect_identical(attr(out, "tzone"), "Europe/Lisbon")
  expect_identical(as.numeric(out), as.numeric(x))
  text <- arrow_to_r(arrow_array(x), lossy = "character")
  expect_match(text, "\\.250000Z$")
})

test_that("difftime exports in microseconds from any unit", {
  x <- as.difftime(c(1.5, NA), units = "mins")
  out <- arrow_to_r(arrow_array(x), lossy = "character")
  expect_identical(as.vector(out), c("90000000", NA))
  expect_identical(attr(out, "arrow_unit"), "us")
})

test_that("Date exports to date32 and date64", {
  x <- as.Date(c("2026-10-21", NA))
  expect_identical(arrow_to_r(arrow_array(x)), x)
  date64 <- arrow_array(x, schema = "tdm")
  expect_identical(
    as.vector(arrow_to_r(date64, lossy = "character")),
    c("2026-10-21T00:00:00.000Z", NA)
  )
  expect_error(
    arrow_array(structure(1.5, class = "Date")),
    class = "zuarrow_lossy_error"
  )
})

test_that("strings are written as UTF-8 whatever their encoding", {
  latin1 <- iconv("café", "UTF-8", "latin1")
  expect_identical(Encoding(latin1), "latin1")
  expect_identical(arrow_to_r(arrow_array(latin1)), "café")
  expect_identical(
    arrow_to_r(arrow_array(c("a", NA), schema = "U")),
    c("a", NA)
  )
})

test_that("invalid UTF-8 and bytes-encoded strings are type errors", {
  bad <- "a\xffb"
  Encoding(bad) <- "UTF-8"
  bytes <- "caf\xe9"
  Encoding(bytes) <- "bytes"
  for (x in list(c("ok", bad), c("ok", bytes))) {
    err <- expect_error(arrow_array(x), class = "zuarrow_type_error")
    expect_match(conditionMessage(err), "row 2")
    expect_error(arrow_array(x, schema = "U"), class = "zuarrow_type_error")
    expect_error(
      arrow_write(data.frame(z = x), NULL),
      class = "zuarrow_type_error"
    )
    f <- structure(1:2, levels = x, class = "factor")
    expect_error(arrow_array(f, schema = "u"), class = "zuarrow_type_error")
    expect_error(arrow_array(f), class = "zuarrow_type_error")
  }
  expect_error(
    arrow_array(structure(bytes, arrow_type = "i")),
    class = "zuarrow_type_error"
  )
})

test_that("a factor code outside its levels is a type error", {
  for (code in c(5L, 0L, -1L)) {
    f <- structure(c(1L, code), levels = "a", class = "factor")
    err <- expect_error(arrow_array(f), class = "zuarrow_type_error")
    expect_match(conditionMessage(err), "row 2")
    expect_error(arrow_array(f, schema = "u"), class = "zuarrow_type_error")
    expect_error(
      arrow_write(data.frame(f = I(f)), NULL, dictionary = FALSE),
      class = "zuarrow_type_error"
    )
  }
  numeric_levels <- structure(1L, levels = 1L, class = "factor")
  expect_error(arrow_array(numeric_levels), class = "zuarrow_type_error")
  expect_error(
    arrow_array(numeric_levels, schema = "u"),
    class = "zuarrow_type_error"
  )
})

test_that("a column name that is not UTF-8 is a type error", {
  for (enc in c("bytes", "UTF-8")) {
    name <- "caf\xe9"
    Encoding(name) <- enc
    df <- data.frame(x = 1L)
    names(df) <- name
    expect_error(arrow_array(df), class = "zuarrow_type_error")
    expect_error(arrow_schema(df), class = "zuarrow_type_error")
  }
})

test_that("strings past utf8's offsets are written as large_utf8", {
  withr::local_options(zuarrow.utf8_limit = 5)
  expect_identical(format(arrow_schema(arrow_array(c("abc", "de")))), "string")
  big <- arrow_array(c("abc", "def"))
  expect_identical(format(arrow_schema(big)), "large_string")
  expect_identical(arrow_to_r(big), c("abc", "def"))
  # A given schema is kept, and its offsets checked.
  expect_identical(
    format(arrow_schema(arrow_array(c("abc", "def"), schema = "u"))),
    "string"
  )
})

test_that("binary checks its elements", {
  expect_error(arrow_array(list(as.raw(1), 1L)), class = "zuarrow_type_error")
  fixed <- arrow_array(list(as.raw(1:2), NULL), schema = "w:2")
  expect_identical(unclass(arrow_to_r(fixed))[1:2], list(as.raw(1:2), NULL))
  expect_error(
    arrow_array(list(as.raw(1)), schema = "w:2"),
    class = "zuarrow_type_error"
  )
  expect_identical(
    arrow_to_r(arrow_array(list(as.raw(1)), schema = "Z")),
    list(as.raw(1))
  )
})

test_that("a data frame must match its struct schema", {
  schema <- arrow_schema(data.frame(x = 1L, y = 1L))
  expect_error(
    arrow_array(data.frame(x = 1L), schema = schema),
    class = "zuarrow_type_error"
  )
})

test_that("every array zuarrow builds passes full validation", {
  values <- list(
    c(TRUE, NA),
    c(1L, NA),
    c(1.5, NA, NaN),
    c("a", NA, "é"),
    as.Date(c("2026-10-21", NA)),
    as.POSIXct(c("2026-10-21", NA), tz = "UTC"),
    as.difftime(c(1, NA), units = "secs"),
    list(as.raw(1), NULL),
    data.frame(x = 1:2, y = c("a", NA))
  )
  for (x in values) {
    expect_true(arrow_validate(arrow_array(x), "full"))
  }
})
