# Nested types, design section 6.4.

test_that("a struct column becomes a nested data frame", {
  df <- data.frame(id = 1:2)
  df$pos <- data.frame(x = c(1.5, 2.5), y = c("a", "b"))
  out <- arrow_to_r(arrow_array(df))
  expect_identical(out, df)
  expect_identical(nrow(out), 2L)
  expect_identical(out$pos$y, c("a", "b"))
})

test_that("null rows of a nested struct are NA in its columns", {
  schema <- arrow_schema(data.frame(s = I(data.frame(x = 1L))))
  inner <- test_array_spec(
    2,
    list(as.raw(0x02), NULL),
    null_count = 1,
    children = list(test_array_spec(2, list(NULL, le_int(c(7, 8), 4L))))
  )
  array <- test_array(schema, 2, list(NULL), children = list(inner))
  out <- arrow_to_r(array)
  expect_identical(out$s$x, c(NA, 8L))
})

test_that("a list column round-trips with NULL and empty elements", {
  x <- list(1:3, NULL, integer(), 4L)
  array <- arrow_array(x)
  expect_identical(format(arrow_schema(array)), "list<item: int32>")
  expect_identical(arrow_to_r(array), x)
  expect_true(arrow_validate(array, "full"))
})

test_that("lists of every exact type round-trip", {
  values <- list(
    list(c(TRUE, NA), FALSE),
    list(c(1.5, NA), NULL),
    list(c("a", NA), character()),
    list(as.Date("2026-10-21") + 0:1, NULL),
    list(list(as.raw(1), NULL), list())
  )
  for (x in values) {
    expect_identical(arrow_to_r(arrow_array(x)), x)
  }
})

test_that("lists nest", {
  x <- list(list(1:2, 3L), NULL, list())
  expect_identical(arrow_to_r(arrow_array(x)), x)
})

test_that("a list of data frames is a list of structs", {
  x <- list(data.frame(a = 1:2, b = c("x", "y")), NULL)
  array <- arrow_array(x)
  expect_identical(
    format(arrow_schema(array)),
    "list<item: struct<a: int32, b: string>>"
  )
  expect_identical(arrow_to_r(array), x)
})

test_that("a list of data frames keeps every row of every element", {
  x <- list(data.frame(a = 1:3), NULL, data.frame(a = 4:5))
  array <- arrow_array(x)
  expect_identical(arrow_to_r(array), x)
  expect_true(arrow_validate(array, "full"))
  df <- data.frame(id = 1:3)
  df$rows <- list(
    data.frame(a = 1:3, b = "x"),
    data.frame(a = 4L, b = "y"),
    NULL
  )
  expect_identical(as.data.frame(arrow_stream(df, batch = 2)), df)
})

test_that("a list column whose values outnumber its offsets is refused", {
  schema <- arrow_schema(list(1:2))
  prep <- structure(
    list(offsets = c(0, 1), null = FALSE, values = 1:3),
    class = "zar_list_prep"
  )
  out <- .Call(zar_c_from_r, prep, schema, 0, 1)
  expect_error(zar_check(out), class = "zuarrow_type_error")
})

test_that("a list column inside a data frame round-trips through a stream", {
  df <- data.frame(id = 1:4)
  df$tags <- list(c("a", "b"), NULL, "c", character())
  expect_identical(as.data.frame(arrow_stream(df, batch = 3)), df)
})

test_that("list elements must share a class", {
  expect_error(arrow_array(list(1L, "a")), class = "zuarrow_type_error")
})

test_that("a large_list round-trips as a list column", {
  x <- list(1:2, NULL, 3L)
  schema <- test_schema(zspec("+L", children = list(zspec("i", "item"))))
  large <- arrow_array(x, schema = schema)
  expect_identical(format(arrow_schema(large)), "large_list<item: int32>")
  expect_identical(arrow_to_r(large), x)
})

test_that("a list_view reads through its offsets and sizes", {
  schema <- test_schema(zspec("+vl", children = list(zspec("i", "item"))))
  view <- test_array(
    schema,
    3,
    list(as.raw(0x05), le_int(c(2, 0, 0), 4L), le_int(c(2, 0, 2), 4L)),
    null_count = 1,
    children = list(test_array_spec(4, list(NULL, le_int(c(1, 2, 3, 4), 4L))))
  )
  expect_identical(arrow_to_r(view), list(3:4, NULL, 1:2))
})

test_that("a fixed_size_list reads as a list column or a matrix", {
  m <- matrix(c(1L, 2L, NA, 4L, 5L, 6L), nrow = 2)
  array <- arrow_array(m, schema = arrow_matrix())
  expect_identical(
    format(arrow_schema(array)),
    "fixed_size_list(3)<item: int32>"
  )
  expect_identical(arrow_to_r(array, to = arrow_matrix()), m)
  expect_identical(arrow_to_r(array), list(c(1L, NA, 5L), c(2L, 4L, 6L)))
})

test_that("a null fixed_size_list row is an NA matrix row", {
  schema <- test_schema(zspec("+w:2", children = list(zspec("g", "item"))))
  array <- test_array(
    schema,
    2,
    list(as.raw(0x01)),
    null_count = 1,
    children = list(test_array_spec(
      4,
      list(NULL, writeBin(c(1, 2, 3, 4), raw(), endian = "little"))
    ))
  )
  out <- arrow_to_r(array, to = arrow_matrix())
  expect_identical(out, matrix(c(1, NA, 2, NA), nrow = 2))
})

test_that("a matrix is written as a fixed_size_list only when asked", {
  expect_error(arrow_array(matrix(1:4, 2)), class = "zuarrow_type_error")
  expect_error(
    arrow_to_r(arrow_array(1:3), to = arrow_matrix()),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_array(1:3, schema = arrow_matrix()),
    class = "zuarrow_type_error"
  )
})

test_that("a map reads as key/value data frames, keeping keys_sorted", {
  schema <- test_schema(zspec(
    "+m",
    children = list(
      zspec(
        "+s",
        "entries",
        flags = 0L,
        children = list(zspec("u", "key", flags = 0L), zspec("i", "value"))
      )
    ),
    flags = 2L + 4L
  ))
  array <- test_array(
    schema,
    2,
    list(NULL, le_int(c(0, 2, 2), 4L)),
    children = list(test_array_spec(
      2,
      list(NULL),
      children = list(
        test_array_spec(2, list(NULL, le_int(c(0, 1, 2), 4L), charToRaw("ab"))),
        test_array_spec(2, list(NULL, le_int(c(1, 2), 4L)))
      )
    ))
  )
  out <- arrow_to_r(array)
  expect_identical(out[[1]], data.frame(key = c("a", "b"), value = 1:2))
  expect_identical(nrow(out[[2]]), 0L)
  expect_true(attr(out, "arrow_keys_sorted"))
})

test_that("a lossy value inside a list fails, or converts under allow", {
  schema <- test_schema(zspec("+l", children = list(zspec("l", "item"))))
  array <- test_array(
    schema,
    1,
    list(NULL, le_int(c(0, 1), 4L)),
    children = list(test_array_spec(1, list(NULL, le_hex("0020000000000001"))))
  )
  expect_error(arrow_to_r(array), class = "zuarrow_lossy_error")
  expect_identical(arrow_to_r(array, lossy = "allow"), list(2^53))
  text <- arrow_to_r(array, lossy = "character")
  expect_identical(as.vector(text[[1]]), "9007199254740993")
})

test_that("nesting deeper than max_depth is a limit error", {
  spec <- zspec("i", "item")
  for (i in 1:70) {
    spec <- zspec("+l", "item", children = list(spec))
  }
  schema <- test_schema(spec)
  empty <- function(depth) {
    if (depth == 0) {
      return(test_array_spec(0, list(NULL, raw())))
    }
    test_array_spec(
      0,
      list(NULL, le_int(0, 4L)),
      children = list(empty(depth - 1))
    )
  }
  array <- test_array(
    schema,
    0,
    list(NULL, le_int(0, 4L)),
    children = list(empty(69))
  )
  expect_error(arrow_to_r(array), class = "zuarrow_limit_error")
})
