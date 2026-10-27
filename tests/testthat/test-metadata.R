test_that("a schema without metadata reads as an empty named vector", {
  expect_identical(
    arrow_metadata(arrow_schema("i")),
    setNames(character(), character())
  )
})

test_that("metadata round-trips, UTF-8 included", {
  schema <- arrow_schema("i")
  # Names set from strings: a non-ASCII name in a call would be a symbol,
  # which the parser can't translate in a C locale.
  metadata <- c("zuarrow", "cr\u00e8me")
  names(metadata) <- c("origin", "caf\u00e9")
  arrow_metadata(schema) <- metadata
  expect_identical(arrow_metadata(schema), metadata)
})

test_that("binary values are kept as raw", {
  schema <- arrow_schema("i")
  arrow_metadata(schema) <- list(text = "a", bytes = as.raw(c(0, 255)))
  metadata <- arrow_metadata(schema)
  expect_type(metadata, "list")
  expect_identical(metadata$text, "a")
  expect_identical(metadata$bytes, as.raw(c(0, 255)))
})

test_that("replacing metadata copies the schema", {
  original <- arrow_schema("i")
  changed <- original
  arrow_metadata(changed) <- c(a = "1")
  expect_length(arrow_metadata(original), 0L)
  expect_identical(arrow_metadata(changed), c(a = "1"))
})

test_that("NULL removes metadata", {
  schema <- arrow_schema("i")
  arrow_metadata(schema) <- c(a = "1")
  arrow_metadata(schema) <- NULL
  expect_length(arrow_metadata(schema), 0L)
})

test_that("metadata of an array or a stream is its schema's", {
  schema <- arrow_schema("i")
  arrow_metadata(schema) <- c(a = "1")
  array <- test_array(
    schema,
    1,
    list(NULL, writeBin(1L, raw(), endian = "little"))
  )
  expect_identical(arrow_metadata(array), c(a = "1"))
  expect_identical(arrow_metadata(test_stream(schema, list())), c(a = "1"))
})

test_that("malformed metadata is a type error", {
  schema <- arrow_schema("i")
  expect_error(
    arrow_metadata(schema) <- "unnamed",
    class = "zuarrow_type_error"
  )
  expect_error(arrow_metadata(schema) <- c(a = 1), class = "zuarrow_type_error")
  expect_error(
    arrow_metadata(schema) <- c(a = NA_character_),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_metadata(schema) <- list(a = 1),
    class = "zuarrow_type_error"
  )
})

test_that("metadata is replaced on schemas only", {
  array <- test_int32(1L)
  expect_error(
    arrow_metadata(array) <- c(a = "1"),
    class = "zuarrow_handle_error"
  )
})
