# Writing the types arrow_array() refused until 2026-11-26: string and
# binary views, half floats, intervals from their text, bit64's integer64,
# and a data frame's columns given chosen types. The oracle is the reader,
# which predates these writers: each round trip gives the input back, and
# the bytes the C builder writes are checked against the layout by hand
# where the reader alone would not see a mistake.

test_that("string_view writes inlined and long strings exactly", {
  x <- c(
    "a",
    NA,
    "",
    "twelve bytes",
    "thirteen byte",
    strrep("é", 40),
    strrep("x", 40000)
  )
  array <- arrow_array(x, schema = "vu")
  expect_identical(format(arrow_schema(array)), "string_view")
  expect_true(arrow_validate(array, "full"))
  expect_identical(arrow_to_r(array), x)
  # A value of at most 12 bytes is inlined after its length; a longer one
  # keeps its first four bytes and names a data buffer. Row 7 does not fit
  # the 32 KB block row 6 opened, so it opens a second one.
  views <- test_array_to_spec(array)$buffers[[2L]]
  view <- function(i) views[(16L * (i - 1L) + 1L):(16L * i)]
  expect_identical(view(1L), c(le_int(1, 4L), charToRaw("a"), raw(11L)))
  expect_identical(view(2L), raw(16L))
  expect_identical(view(4L), c(le_int(12, 4L), charToRaw("twelve bytes")))
  expect_identical(
    view(5L),
    c(le_int(13, 4L), charToRaw("thir"), le_int(0, 4L), le_int(0, 4L))
  )
  expect_identical(
    view(7L),
    c(le_int(40000, 4L), charToRaw("xxxx"), le_int(1, 4L), le_int(0, 4L))
  )
  expect_identical(
    arrow_to_r(arrow_array(factor(c("b", NA, "a")), schema = "vu")),
    c("b", NA, "a")
  )
})

test_that("binary_view writes a list of raw vectors exactly", {
  x <- list(as.raw(1:3), NULL, raw(), as.raw(0:12), as.raw(rep(255, 100)))
  array <- arrow_array(x, schema = "vz")
  expect_identical(format(arrow_schema(array)), "binary_view")
  expect_true(arrow_validate(array, "full"))
  expect_identical(arrow_to_r(array), x)
  expect_error(
    arrow_array(list(as.raw(1), "a"), schema = "vz"),
    class = "zuarrow_type_error"
  )
  expect_error(arrow_array(1:3, schema = "vz"), class = "zuarrow_type_error")
})

test_that("a string_view with a value that is not UTF-8 names its row", {
  bad <- c("ok", "\xff\xfe")
  Encoding(bad) <- "UTF-8"
  err <- expect_error(
    arrow_array(bad, schema = "vu"),
    class = "zuarrow_type_error"
  )
  expect_match(conditionMessage(err), "row 2")
})

test_that("half_float writes every double it holds exactly", {
  x <- c(
    0.5,
    NA,
    -2,
    65504,
    -65504,
    2^-14, # the smallest normal
    2^-24, # the smallest subnormal
    1023 * 2^-24, # the largest subnormal
    1 + 2^-10,
    -0,
    0,
    Inf,
    -Inf,
    NaN
  )
  array <- arrow_array(x, schema = "e")
  expect_true(arrow_validate(array, "full"))
  back <- arrow_to_r(array)
  expect_identical(back, x)
  expect_identical(1 / back[c(10L, 11L)], c(-Inf, Inf))
  # The bits, against IEEE 754 binary16 by hand.
  expect_identical(
    test_array_to_spec(array)$buffers[[2L]],
    le_int(
      c(
        0x3800,
        0,
        0xc000,
        0x7bff,
        0xfbff,
        0x0400,
        0x0001,
        0x03ff,
        0x3c01,
        0x8000,
        0,
        0x7c00,
        0xfc00,
        0x7e00
      ),
      2L
    )
  )
  expect_identical(
    arrow_to_r(arrow_array(c(1L, NA, -7L), schema = "e")),
    c(1, NA, -7)
  )
})

test_that("a double a half_float cannot hold is a lossy error naming the row", {
  cases <- list(
    c(1, 1 / 3), # more than 11 significant bits
    c(1, 65520), # past the largest half
    c(1, 2^-25), # below the smallest subnormal
    c(1, 1 + 2^-11), # one bit too many
    c(1, 3 * 2^-25) # between two subnormals
  )
  for (x in cases) {
    err <- expect_error(
      arrow_array(x, schema = "e"),
      class = "zuarrow_lossy_error"
    )
    expect_identical(err$row, 2, info = format(x[[2L]]))
  }
})

test_that("intervals write back the text arrow_to_r() gives them", {
  values <- list(
    tiM = c("14M", NA, "-1M", "0M", "2147483647M", "-2147483648M"),
    tiD = c("3d1500ms", NA, "-2d0ms", "0d-1ms", "-2147483648d2147483647ms"),
    tin = c(
      "1M-2d3ns",
      NA,
      "0M0d0ns",
      "2147483647M-2147483648d9223372036854775807ns",
      "0M0d-9223372036854775808ns"
    )
  )
  for (format in names(values)) {
    x <- structure(values[[format]], arrow_type = format)
    array <- arrow_array(x)
    expect_identical(
      format(arrow_schema(array)),
      format(arrow_schema(format)),
      info = format
    )
    expect_true(arrow_validate(array, "full"), info = format)
    expect_identical(arrow_to_r(array, lossy = "character"), x, info = format)
    expect_identical(
      arrow_to_r(array, to = character()),
      x,
      info = format
    )
    # Under every other policy an interval still has no R form.
    for (lossy in c("error", "warn", "allow")) {
      expect_error(
        arrow_to_r(array, lossy = lossy),
        class = "zuarrow_lossy_error"
      )
    }
  }
  # The bytes, against the layout by hand: int32 months; int32 days then
  # int32 milliseconds; int32 months, int32 days, int64 nanoseconds.
  bytes <- function(text, format) {
    array <- arrow_array(structure(text, arrow_type = format))
    test_array_to_spec(array)$buffers[[2L]]
  }
  expect_identical(bytes("-1M", "tiM"), le_int(-1, 4L))
  expect_identical(
    bytes("3d-1500ms", "tiD"),
    c(le_int(3, 4L), le_int(-1500, 4L))
  )
  expect_identical(
    bytes("1M-2d3ns", "tin"),
    c(le_int(1, 4L), le_int(-2, 4L), le_int(3, 8L))
  )
})

test_that("an interval inside a struct and a list reads as its text", {
  df <- data.frame(id = 1:2)
  df$i <- structure(c("1M2d3ns", NA), arrow_type = "tin")
  expect_identical(arrow_to_r(arrow_array(df), lossy = "character"), df)
  expect_error(arrow_to_r(arrow_array(df)), class = "zuarrow_lossy_error")
})

test_that("only the canonical interval text is read", {
  lossy <- list(
    tiM = c("+1M", "01M", "-0M", "2147483648M", "-2147483649M"),
    tiD = c("1d+1ms", "1d01ms", "-0d1ms", "1d2147483648ms"),
    tin = c("1M1d+1ns", "1M1d9223372036854775808ns", "1M-0d1ns")
  )
  not_text <- list(
    tiM = c("1", "M", "1m", "1M ", " 1M", "1M1d", "1.5M", ""),
    tiD = c("1d", "1d1", "1ms1d", "1d1s", "1D1ms"),
    tin = c("1M1d", "1M1d1ms", "1d1M1ns", "1M1d1nsx")
  )
  for (format in names(lossy)) {
    for (text in lossy[[format]]) {
      expect_error(
        arrow_array(structure(text, arrow_type = format)),
        class = "zuarrow_lossy_error"
      )
    }
    for (text in not_text[[format]]) {
      expect_error(
        arrow_array(structure(text, arrow_type = format)),
        class = "zuarrow_type_error"
      )
    }
  }
  err <- expect_error(
    arrow_array(structure(c("1M", "01M"), arrow_type = "tiM")),
    class = "zuarrow_lossy_error"
  )
  expect_identical(err$row, 2)
})

test_that("zero-length columns of every new type write and read back", {
  df <- data.frame(
    vu = character(),
    h = double(),
    i64 = double()
  )
  df$vz <- list()
  df$m <- structure(character(), arrow_type = "tiM")
  df$d <- structure(character(), arrow_type = "tiD")
  df$n <- structure(character(), arrow_type = "tin")
  df$i64 <- test_integer64(integer(), integer())
  types <- c(vu = "vu", h = "e", vz = "vz")
  stream <- arrow_stream(df, schema = types)
  expect_identical(
    format(arrow_schema(stream)),
    paste0(
      "struct<vu: string_view, h: half_float, i64: int64, vz: binary_view, ",
      "m: interval_months, d: interval_day_time, n: interval_month_day_nano>"
    )
  )
  batch <- arrow_next(stream, lossy = "character")
  expect_identical(batch$vu, character())
  expect_identical(batch$n, df$n)
  expect_identical(arrow_next(stream), NULL)
  for (format in c("vu", "vz", "e", "tiM", "tiD", "tin")) {
    x <- switch(
      format,
      vu = character(),
      vz = list(),
      e = double(),
      structure(character(), arrow_type = format)
    )
    array <- arrow_array(x, schema = format)
    expect_identical(arrow_info_length(array), 0, info = format)
    expect_true(arrow_validate(array, "full"), info = format)
  }
})

test_that("an integer64 writes as int64, and as any integer type when asked", {
  # 1, -5, NA, 2^32, INT64_MAX and INT64_MIN + 1.
  x <- test_integer64(
    c(1, -5, 0, 0, -1, 1),
    c(0, -1, NA, 1, 2147483647, NA)
  )
  array <- arrow_array(x)
  expect_identical(format(arrow_schema(array)), "int64")
  text <- c(
    "1",
    "-5",
    NA,
    "4294967296",
    "9223372036854775807",
    "-9223372036854775807"
  )
  expect_identical(
    arrow_to_r(array, lossy = "character"),
    structure(text, arrow_type = "l")
  )
  # bit64's integer64 back under lossy = "allow", when bit64 is loaded.
  local_mocked_bindings(zar_bit64_loaded = function() TRUE)
  expect_identical(arrow_to_r(array, lossy = "allow"), x)

  small <- test_integer64(c(1, -5, 0, 127), c(0, -1, NA, 0))
  for (format in c("c", "s", "i", "l")) {
    expect_identical(
      arrow_to_r(arrow_array(small, schema = format)),
      if (format == "l") c(1, -5, NA, 127) else c(1L, -5L, NA, 127L),
      info = format
    )
  }
  expect_identical(
    arrow_to_r(arrow_array(
      test_integer64(c(0, 255, 0), c(0, 0, NA)),
      schema = "C"
    )),
    c(0L, 255L, NA)
  )
  expect_identical(
    arrow_to_r(
      arrow_array(test_integer64(c(1, 0, 0), c(0, NA, 1)), schema = "L"),
      lossy = "character"
    ),
    c(1, NA, 2^32)
  )
})

test_that("an integer64 a type cannot hold is a lossy error naming the row", {
  x <- test_integer64(c(1, -5), c(0, -1))
  for (format in c("C", "S", "I", "L")) {
    err <- expect_error(
      arrow_array(x, schema = format),
      class = "zuarrow_lossy_error"
    )
    expect_identical(err$row, 2, info = format)
  }
  big <- test_integer64(c(1, 0), c(0, 1))
  for (format in c("c", "s", "i", "I")) {
    err <- expect_error(
      arrow_array(big, schema = format),
      class = "zuarrow_lossy_error"
    )
    expect_identical(err$row, 2, info = format)
  }
  expect_error(arrow_array(x, schema = "g"), class = "zuarrow_type_error")
})

test_that("a list of integer64 vectors is a list of int64", {
  x <- list(test_integer64(c(1, 2), c(0, 0)), NULL, test_integer64(3, 1))
  array <- arrow_array(x)
  expect_identical(format(arrow_schema(array)), "list<item: int64>")
  expect_identical(arrow_to_r(array), list(c(1, 2), NULL, 3 + 2^32))
})

test_that("a named character vector gives a data frame's columns their types", {
  df <- data.frame(
    f = 1.5,
    sv = "x",
    h = 0.5,
    n = NA,
    d = as.Date("2026-11-26")
  )
  df$lz <- list(as.raw(1:3))
  types <- c(lz = "Z", f = "f", sv = "vu", h = "e", n = "n", d = "tdm")
  for (build in list(arrow_array, arrow_stream)) {
    x <- build(df, schema = types)
    expect_identical(
      format(arrow_schema(x)),
      paste0(
        "struct<f: float, sv: string_view, h: half_float, n: na, ",
        "d: date64, lz: large_binary>"
      )
    )
  }
  back <- as.data.frame(arrow_stream(df, schema = types), lossy = "character")
  expect_identical(
    back[c("f", "sv", "h", "n", "lz")],
    df[c("f", "sv", "h", "n", "lz")]
  )
  expect_identical(
    back$d,
    structure("2026-11-26T00:00:00.000Z", arrow_type = "tdm")
  )
  # A column not named keeps its default type.
  expect_identical(
    format(arrow_schema(arrow_array(df, schema = c(h = "e")))),
    paste0(
      "struct<f: double, sv: string, h: half_float, n: bool, ",
      "d: date32, lz: binary>"
    )
  )
  # A value the chosen type cannot hold is still an error.
  expect_error(
    arrow_array(data.frame(h = c(1, 1 / 3)), schema = c(h = "e")),
    class = "zuarrow_lossy_error"
  )
})

test_that("arrow_schema() of a named character vector is a struct", {
  schema <- arrow_schema(c(a = "i", b = "vu", c = "tiM", d = "e"))
  expect_identical(
    format(schema),
    "struct<a: int32, b: string_view, c: interval_months, d: half_float>"
  )
  # A data frame with those columns writes as that schema.
  df <- data.frame(a = 1:2, b = c("x", "y"), d = c(0.5, NA))
  df$c <- structure(c("1M", NA), arrow_type = "tiM")
  df <- df[c("a", "b", "c", "d")]
  array <- arrow_array(df, schema = schema)
  expect_identical(arrow_to_r(array, lossy = "character"), df)
})

test_that("a named character vector of types is checked", {
  df <- data.frame(a = 1:2, b = c("x", "y"))
  expect_error(
    arrow_array(df, schema = c(z = "i")),
    "`z`",
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_array(df, schema = c(a = NA_character_)),
    class = "zuarrow_format_error"
  )
  expect_error(
    arrow_array(df, schema = c(a = "")),
    class = "zuarrow_format_error"
  )
  expect_error(
    arrow_array(df, schema = c(a = "zz")),
    class = "zuarrow_format_error"
  )
  expect_error(
    arrow_array(df, schema = c(a = "i", a = "l")),
    class = "zuarrow_type_error"
  )
  expect_error(arrow_schema(c(a = "i", "l")), class = "zuarrow_type_error")
  expect_error(
    arrow_array(df, schema = c(a = "+l")),
    class = "zuarrow_type_error"
  )
  dup <- data.frame(a = 1, a = 2, check.names = FALSE)
  expect_error(
    arrow_array(dup, schema = c(a = "l")),
    class = "zuarrow_type_error"
  )
  # A nested column may be named with the format it already has.
  nested <- data.frame(id = 1:2)
  nested$l <- list(1:2, 3L)
  expect_identical(
    format(arrow_schema(arrow_array(nested, schema = c(l = "+l", id = "l")))),
    "struct<id: int64, l: list<item: int32>>"
  )
  # Not a data frame: the struct of the types, which a vector cannot fill.
  expect_error(
    arrow_array(1:2, schema = c(a = "i")),
    class = "zuarrow_type_error"
  )
})

test_that("an I() column is written as its value", {
  df <- data.frame(id = 1:2, b = I(list(as.raw(1), NULL)))
  expect_identical(format(arrow_schema(df)), "struct<id: int32, b: binary>")
  expect_identical(arrow_to_r(arrow_array(df))$b, list(as.raw(1), NULL))
  expect_identical(arrow_to_r(arrow_array(I(1:3))), 1:3)
})
