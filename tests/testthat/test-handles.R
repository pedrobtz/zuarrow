test_that("handles carry zuarrow's class before nanoarrow's", {
  expect_identical(
    class(arrow_schema("i")),
    c("zuarrow_schema", "nanoarrow_schema")
  )
  expect_identical(
    class(test_int32(1:3)),
    c("zuarrow_array", "nanoarrow_array")
  )
  expect_identical(
    class(test_stream("i", list(test_int32(1:3)))),
    c("zuarrow_array_stream", "nanoarrow_array_stream")
  )
})

test_that("arrow_schema() reads every primitive format string", {
  formats <- c(
    n = "na",
    b = "bool",
    c = "int8",
    C = "uint8",
    s = "int16",
    S = "uint16",
    i = "int32",
    I = "uint32",
    l = "int64",
    L = "uint64",
    e = "half_float",
    f = "float",
    g = "double",
    z = "binary",
    Z = "large_binary",
    u = "string",
    U = "large_string",
    vz = "binary_view",
    vu = "string_view",
    tdD = "date32",
    tdm = "date64",
    tDs = "duration('s')"
  )
  for (f in names(formats)) {
    schema <- arrow_schema(f)
    expect_s3_class(schema, "zuarrow_schema")
    expect_identical(format(schema), formats[[f]], info = f)
  }
})

test_that("arrow_schema() reads parameterised format strings", {
  expect_identical(format(arrow_schema("d:10,2")), "decimal128(10, 2)")
  expect_identical(format(arrow_schema("w:4")), "fixed_size_binary(4)")
  expect_match(format(arrow_schema("tsn:UTC")), "timestamp\\('ns', 'UTC'\\)")
  expect_match(format(arrow_schema("tsu:")), "timestamp\\('us', ''\\)")
})

test_that("an invalid or incomplete format string is a format error", {
  expect_error(arrow_schema("zz"), class = "zuarrow_format_error")
  expect_error(arrow_schema(""), class = "zuarrow_format_error")
  expect_error(arrow_schema(NA_character_), class = "zuarrow_format_error")
  # A nested format names no children, so on its own it is incomplete.
  expect_error(arrow_schema("+l"), class = "zuarrow_format_error")
  expect_error(arrow_schema("d:10"), class = "zuarrow_format_error")
})

test_that("arrow_schema() infers the type an R object is written with", {
  spec <- function(x) .Call(zuarrow:::zar_c_schema_to_spec, arrow_schema(x))
  expect_identical(spec(c(TRUE, NA))$format, "b")
  expect_identical(spec(1:3)$format, "i")
  expect_identical(spec(c(1.5, 2))$format, "g")
  expect_identical(spec(c("a", "b"))$format, "u")
  expect_identical(spec(NULL)$format, "n")
  expect_identical(spec(as.Date("2026-10-21"))$format, "tdD")
  expect_identical(spec(as.POSIXct("2026-10-21", tz = "UTC"))$format, "tsu:UTC")
  expect_identical(
    spec(as.POSIXct("2026-10-21", tz = "Europe/Lisbon"))$format,
    "tsu:Europe/Lisbon"
  )
  expect_identical(spec(as.difftime(1, units = "secs"))$format, "tDu")
  expect_identical(spec(list(as.raw(1:2), NULL))$format, "z")

  list_spec <- spec(list(1:2, 3L))
  expect_identical(list_spec$format, "+l")
  expect_identical(list_spec$children[[1]]$format, "i")
})

test_that("a factor infers a dictionary with the ordered flag", {
  spec <- function(x) .Call(zuarrow:::zar_c_schema_to_spec, arrow_schema(x))
  plain <- spec(factor(c("a", "b")))
  expect_identical(plain$format, "i")
  expect_identical(plain$dictionary$format, "u")
  expect_identical(bitwAnd(plain$flags, 1L), 0L)
  expect_identical(bitwAnd(spec(factor("a", ordered = TRUE))$flags, 1L), 1L)
})

test_that("a data frame infers a struct with one named field per column", {
  df <- data.frame(x = 1:2, y = c("a", "b"))
  df$pos <- data.frame(lat = c(1, 2), lon = c(3, 4))
  spec <- .Call(zuarrow:::zar_c_schema_to_spec, arrow_schema(df))
  expect_identical(spec$format, "+s")
  expect_identical(vapply(spec$children, `[[`, "", "name"), c("x", "y", "pos"))
  expect_identical(spec$children[[3]]$format, "+s")
  expect_identical(
    format(arrow_schema(df)),
    "struct<x: int32, y: string, pos: struct<lat: double, lon: double>>"
  )
})

test_that("an R class with no Arrow type is a type error", {
  expect_error(arrow_schema(1i), class = "zuarrow_type_error")
  expect_error(
    arrow_schema(structure(1, class = "my_class")),
    class = "zuarrow_type_error"
  )
})

test_that("arrow_schema() returns its own schema and copies the others", {
  schema <- arrow_schema("i")
  expect_identical(arrow_schema(schema), schema)

  array <- test_int32(1:3)
  expect_identical(format(arrow_schema(array)), "int32")

  stream <- test_stream("i", list(test_int32(1:3)))
  expect_identical(format(arrow_schema(stream)), "int32")
  # Reading the schema does not consume the stream.
  expect_identical(format(arrow_schema(stream)), "int32")
  expect_true(arrow_validate(stream))
})

test_that("a released handle is a handle error and prints as released", {
  array <- test_int32(1:3)
  stream <- test_stream("i", list(array))
  # The stream took ownership, leaving the array handle released.
  expect_error(arrow_schema(array), class = "zuarrow_handle_error")
  expect_error(arrow_validate(array), class = "zuarrow_handle_error")
  expect_identical(format(array), "<zuarrow_array [released]>")
  expect_s3_class(stream, "zuarrow_array_stream")
})

test_that("a foreign or NULL pointer is a handle error", {
  null_schema <- structure(new("externalptr"), class = "nanoarrow_schema")
  expect_error(arrow_schema(null_schema), class = "zuarrow_handle_error")
  expect_error(arrow_validate(1:3), class = "zuarrow_handle_error")
  expect_error(arrow_metadata("i"), class = "zuarrow_handle_error")
  not_ours <- structure(new("externalptr"), class = "something_else")
  expect_error(arrow_validate(not_ours), class = "zuarrow_handle_error")
})

test_that("every condition inherits from zuarrow_error", {
  expect_error(arrow_schema("zz"), class = "zuarrow_error")
  expect_error(arrow_schema(1i), class = "zuarrow_error")
  expect_error(arrow_validate(1), class = "zuarrow_error")
})

test_that("handles print their type", {
  expect_output(print(arrow_schema("l")), "<zuarrow_schema> int64")
  expect_output(print(test_int32(1:3)), "<zuarrow_array int32\\[3\\]>")
  expect_output(print(test_stream("i", list())), "<zuarrow_array_stream int32>")
})

test_that("finalizers release handles without error", {
  for (i in 1:50) {
    stream <- test_stream("i", list(test_int32(1:10), test_int32(1:5)))
  }
  rm(stream)
  # An error in a finalizer does not reach gc()'s caller, so this test fails
  # only by crashing, as a double free or a bad release would.
  expect_no_error(gc())
})

test_that("a released stream is a handle error", {
  skip_if_not_installed("nanoarrow")
  stream <- arrow_stream(data.frame(a = 1:3))
  nanoarrow::nanoarrow_pointer_release(stream)
  expect_error(arrow_next(stream), class = "zuarrow_handle_error")
  expect_error(arrow_to_r(stream), class = "zuarrow_handle_error")
  expect_error(arrow_validate(stream), class = "zuarrow_handle_error")
})

test_that("an array whose schema was released is a handle error", {
  skip_if_not_installed("nanoarrow")
  array <- arrow_array(1:3)
  # nanoarrow returns the array's own schema, the handle's tag, not a copy.
  nanoarrow::nanoarrow_pointer_release(nanoarrow::infer_nanoarrow_schema(array))
  expect_error(arrow_to_r(array), class = "zuarrow_handle_error")
  expect_error(arrow_schema(array), class = "zuarrow_handle_error")
  expect_error(arrow_validate(array), class = "zuarrow_handle_error")
})
