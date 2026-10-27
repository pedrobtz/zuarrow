# Exact or error, design section 6.3.

test_that("an int64 past 2^53 is a lossy error naming the row and zuint", {
  big <- test_array(
    "l",
    3,
    list(NULL, c(le_int(c(1, 2), 8L), le_hex("0020000000000001")))
  )
  err <- tryCatch(arrow_to_r(big), zuarrow_lossy_error = function(e) e)
  expect_s3_class(err, "zuarrow_lossy_error")
  expect_s3_class(err, "zuarrow_error")
  expect_identical(err$row, 3)
  expect_identical(err$target, "zuint")
  expect_identical(err$arrow_type, "l")
})

test_that("each row of the lossy table errors by default and converts under allow", {
  ns <- arrow_array(
    as.POSIXct("2026-10-21 10:00:00", tz = "UTC"),
    schema = "tsn:UTC"
  )
  us <- arrow_array(as.POSIXct("2026-10-21 10:00:00", tz = "UTC"))
  cases <- list(
    int64 = test_array("l", 1, list(NULL, le_hex("0020000000000001"))),
    uint64 = test_array("L", 1, list(NULL, le_hex("0020000000000001"))),
    decimal32 = test_fixed("d:5,2,32", 12345, 4L),
    decimal64 = test_fixed("d:5,2,64", 12345, 8L),
    decimal128 = test_fixed("d:5,2", 12345, 16L),
    decimal256 = test_fixed("d:5,2,256", 12345, 32L),
    timestamp_us = us,
    timestamp_ns = ns,
    date64 = test_fixed("tdm", 86400000, 8L),
    time32 = test_fixed("tts", 3723, 4L),
    time64 = test_fixed("ttn", 3723e9, 8L),
    duration = test_fixed("tDs", 90, 8L)
  )
  for (name in names(cases)) {
    expect_error(
      arrow_to_r(cases[[name]]),
      class = "zuarrow_lossy_error",
      info = name
    )
    expect_no_error(arrow_to_r(cases[[name]], lossy = "allow"))
  }
})

test_that("the lossy forms of section 6.2 are what allow returns", {
  expect_identical(
    arrow_to_r(test_fixed("d:5,2", 12345, 16L), lossy = "allow"),
    123.45
  )
  expect_identical(
    arrow_to_r(test_fixed("d:5,2", -12345, 16L), lossy = "allow"),
    -123.45
  )
  expect_s3_class(
    arrow_to_r(test_fixed("tdm", 86400000, 8L), lossy = "allow"),
    "POSIXct"
  )
  time <- arrow_to_r(test_fixed("tts", 3723, 4L), lossy = "allow")
  expect_s3_class(time, "difftime")
  expect_identical(as.numeric(time, units = "secs"), 3723)
  duration <- arrow_to_r(test_fixed("tDm", 1500, 8L), lossy = "allow")
  expect_identical(as.numeric(duration, units = "secs"), 1.5)
})

test_that("character gives the exact text and records the type", {
  text <- function(x) {
    out <- arrow_to_r(x, lossy = "character")
    expect_identical(attr(out, "arrow_type"), arrow_schema(x) |> format_of())
    as.vector(out)
  }
  expect_identical(
    text(test_array("l", 1, list(NULL, le_hex("0020000000000001")))),
    "9007199254740993"
  )
  expect_identical(
    text(test_array("L", 1, list(NULL, le_hex("FFFFFFFFFFFFFFFF")))),
    "18446744073709551615"
  )
  expect_identical(
    text(test_fixed("d:5,2", c(12345, -12345, 5), 16L)),
    c("123.45", "-123.45", "0.05")
  )
  expect_identical(text(test_fixed("d:40,3,256", 1, 32L)), "0.001")
  expect_identical(
    text(test_fixed("tsn:UTC", 1500000001, 8L)),
    "1970-01-01T00:00:01.500000001Z"
  )
  expect_identical(
    text(test_fixed("tsu:", -1, 8L)),
    "1969-12-31T23:59:59.999999"
  )
  # The int64 extremes, where the fraction must not be found by multiplying.
  expect_identical(
    text(test_array("tsn:UTC", 1, list(NULL, le_hex("8000000000000000")))),
    "1677-09-21T00:12:43.145224192Z"
  )
  expect_identical(
    text(test_array("tsn:UTC", 1, list(NULL, le_hex("7FFFFFFFFFFFFFFF")))),
    "2262-04-11T23:47:16.854775807Z"
  )
  expect_identical(
    text(test_fixed("tdm", 86400000, 8L)),
    "1970-01-02T00:00:00.000Z"
  )
  expect_identical(text(test_fixed("tts", 3723, 4L)), "01:02:03")
  expect_identical(text(test_fixed("ttm", 3723004, 4L)), "01:02:03.004")
  expect_identical(text(test_fixed("ttu", 3723000005, 8L)), "01:02:03.000005")
})

test_that("a duration's text carries its unit", {
  out <- arrow_to_r(test_fixed("tDm", c(1500, -2), 8L), lossy = "character")
  expect_identical(as.vector(out), c("1500", "-2"))
  expect_identical(attr(out, "arrow_unit"), "ms")
})

test_that("intervals and unions always fail", {
  interval <- test_array("tiM", 1, list(NULL, le_int(1, 4L)))
  for (lossy in c("error", "character", "warn", "allow")) {
    expect_error(
      arrow_to_r(interval, lossy = lossy),
      class = "zuarrow_lossy_error"
    )
  }
  union_schema <- test_schema(zspec("+us:0", children = list(zspec("i", "a"))))
  union <- test_array(
    union_schema,
    1,
    list(as.raw(0)),
    children = list(test_array_spec(1, list(NULL, le_int(7, 4L))))
  )
  expect_error(
    arrow_to_r(union, lossy = "allow"),
    class = "zuarrow_lossy_error"
  )
})

test_that("warn converts with one warning per lossy column", {
  big <- test_array("l", 1, list(NULL, le_hex("0020000000000001")))
  expect_warning(
    out <- arrow_to_r(big, lossy = "warn"),
    class = "zuarrow_lossy_warning"
  )
  expect_identical(out, 2^53)
})

test_that("allow gives integer64 when bit64 is loaded", {
  local_mocked_bindings(zar_bit64_loaded = function() TRUE)
  big <- test_array(
    "l",
    2,
    list(as.raw(0x01), le_hex("0020000000000001") |> c(le_int(0))),
    null_count = 1
  )
  out <- arrow_to_r(big, lossy = "allow")
  expect_s3_class(out, "integer64")
  bits <- writeBin(unclass(out), raw(), endian = "little")
  expect_identical(bits[1:8], le_hex("0020000000000001"))
  expect_identical(bits[9:16], le_hex("8000000000000000"))
})

test_that("int32 INT_MIN is lossy, and NA under allow", {
  min_int <- test_array(
    "i",
    1,
    list(NULL, writeBin(NA_integer_, raw(), endian = "little"))
  )
  expect_error(arrow_to_r(min_int), class = "zuarrow_lossy_error")
  expect_identical(
    as.vector(arrow_to_r(min_int, lossy = "character")),
    "-2147483648"
  )
  expect_identical(arrow_to_r(min_int, lossy = "allow"), NA_integer_)
})

test_that("an embedded NUL is lossy with no text form", {
  nul <- test_utf8(c(0L, 3L), as.raw(c(0x61, 0x00, 0x62)))
  expect_error(arrow_to_r(nul), class = "zuarrow_lossy_error")
  expect_error(
    arrow_to_r(nul, lossy = "character"),
    class = "zuarrow_lossy_error"
  )
  expect_identical(arrow_to_r(nul, lossy = "allow"), "a")
})

test_that("the scan finds lossy values in any batch of a stream", {
  schema <- arrow_schema("l")
  stream <- test_stream(
    schema,
    list(
      test_fixed("l", c(1, 2), 8L),
      test_array("l", 1, list(NULL, le_hex("0020000000000001")))
    )
  )
  err <- tryCatch(arrow_to_r(stream), zuarrow_lossy_error = function(e) e)
  expect_identical(err$row, 3)
})

test_that("to names the R type a column must become", {
  df <- arrow_array(data.frame(n = c(1L, 2L), m = c(3L, 4L)))
  out <- arrow_to_r(df, to = list(n = character(), m = double()))
  expect_identical(out$n, structure(c("1", "2"), arrow_type = "i"))
  expect_identical(out$m, c(3, 4))

  small <- test_fixed("l", c(1, 2), 8L)
  expect_identical(arrow_to_r(small, to = integer()), c(1L, 2L))
  big <- test_fixed("l", 3e9, 8L)
  expect_error(arrow_to_r(big, to = integer()), class = "zuarrow_lossy_error")
})

test_that("to = integer() checks uint32 and uint64 at the range limits", {
  for (format in c("I", "L")) {
    width <- if (format == "I") 4L else 8L
    fits <- test_fixed(format, c(0, 2^31 - 1), width)
    expect_identical(
      arrow_to_r(fits, to = integer()),
      c(0L, .Machine$integer.max)
    )
    past <- test_fixed(format, c(0, 2^31), width)
    err <- expect_error(
      arrow_to_r(past, to = integer()),
      class = "zuarrow_lossy_error"
    )
    expect_identical(err$row, 2)
  }
  top <- test_array(
    test_schema(zspec("L")),
    1,
    list(NULL, le_hex("ffffffffffffffff"))
  )
  expect_error(arrow_to_r(top, to = integer()), class = "zuarrow_lossy_error")
})

test_that("a target that cannot take the column is a type error", {
  expect_error(
    arrow_to_r(arrow_array(TRUE), to = character()),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_to_r(arrow_array("a"), to = double()),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_to_r(arrow_array(1L), to = list()),
    class = "zuarrow_type_error"
  )
  df <- arrow_array(data.frame(n = 1L))
  expect_error(
    arrow_to_r(df, to = list(nope = double())),
    class = "zuarrow_type_error"
  )
  expect_error(arrow_to_r(df, to = double()), class = "zuarrow_type_error")
})

test_that("an unknown policy is an error", {
  expect_error(arrow_to_r(arrow_array(1L), lossy = "round"))
})

test_that("the exact text is written back as the type it names", {
  arrays <- list(
    test_array(
      "l",
      2,
      list(NULL, c(le_hex("0020000000000001"), le_int(-5, 8L)))
    ),
    test_array("L", 1, list(NULL, le_hex("FFFFFFFFFFFFFFFF"))),
    test_fixed("i", -2147483648, 4L),
    test_fixed("c", c(-128, 127), 1L),
    test_fixed("d:5,2", c(12345, -12345, 5, 0), 16L),
    test_fixed("d:9,3,32", c(-999999999, 1), 4L),
    test_fixed("d:18,0,64", c(123456789012345), 8L),
    test_fixed("d:40,3,256", c(1, -2), 32L),
    test_fixed("tsn:UTC", c(1500000001, -1), 8L),
    test_fixed("tsu:", c(0, -1, 1761040800123456), 8L),
    test_fixed("tss:Europe/Lisbon", c(-62135596800, 253402300799), 8L),
    test_fixed("tdm", c(86400000, -1), 8L),
    test_fixed("tts", c(3723, 86399), 4L),
    test_fixed("ttm", 3723004, 4L),
    test_fixed("ttn", c(3723000000005, 0), 8L),
    test_fixed("tDs", c(90, -3), 8L),
    test_fixed("tDn", 1, 8L)
  )
  for (array in arrays) {
    # to = character() asks for the text even where the default is exact.
    text <- arrow_to_r(array, to = character())
    back <- arrow_array(text)
    expect_true(
      arrow_equal(back, array, metadata = FALSE),
      info = attr(text, "arrow_type")
    )
  }
})

test_that("text written back keeps its nulls", {
  array <- test_array(
    "l",
    2,
    list(as.raw(0x02), le_int(c(0, 7), 8L)),
    null_count = 1
  )
  text <- arrow_to_r(array, to = character())
  expect_identical(as.vector(text), c(NA, "7"))
  expect_true(arrow_equal(arrow_array(text), array))
})

test_that("text that is not the type's form is a type error", {
  bad <- function(text, type) arrow_array(structure(text, arrow_type = type))
  expect_error(bad("12a", "l"), class = "zuarrow_type_error")
  expect_error(bad("", "l"), class = "zuarrow_type_error")
  expect_error(bad("1.5", "d:5,0"), class = "zuarrow_lossy_error")
  expect_error(bad("123.456", "d:5,2"), class = "zuarrow_lossy_error")
  expect_error(bad("1234.5", "d:5,2"), class = "zuarrow_lossy_error")
  expect_error(
    bad("2026-02-30T00:00:00Z", "tss:UTC"),
    class = "zuarrow_type_error"
  )
  expect_error(
    bad("2026-10-21T00:00:00", "tss:UTC"),
    class = "zuarrow_type_error"
  )
  expect_error(
    bad("2026-10-21T00:00:00.5Z", "tss:UTC"),
    class = "zuarrow_lossy_error"
  )
  expect_error(bad("01:02", "tts"), class = "zuarrow_type_error")
  expect_error(bad("300", "c"), class = "zuarrow_lossy_error")
  expect_error(bad("-1", "L"), class = "zuarrow_type_error")
  expect_error(bad("9223372036854775808", "l"), class = "zuarrow_lossy_error")
  expect_error(
    arrow_array(structure("1", arrow_type = c("l", "i"))),
    class = "zuarrow_type_error"
  )
})

test_that("a parsed decimal at full precision round-trips", {
  text <- structure(c("99999.99", "-0.01", "0"), arrow_type = "d:7,2")
  expect_identical(
    as.vector(arrow_to_r(arrow_array(text), lossy = "character")),
    c("99999.99", "-0.01", "0.00")
  )
})
