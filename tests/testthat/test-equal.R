test_that("schemas compare by format, name, flags and children", {
  expect_true(arrow_equal(arrow_schema("i"), arrow_schema("i")))
  expect_false(arrow_equal(arrow_schema("i"), arrow_schema("l")))
  expect_false(arrow_equal(
    arrow_schema(data.frame(x = 1L)),
    arrow_schema(data.frame(y = 1L))
  ))
  expect_false(arrow_equal(
    arrow_schema(data.frame(x = 1L)),
    arrow_schema(data.frame(x = 1L, y = 1L))
  ))
  expect_false(arrow_equal(
    arrow_schema(factor("a")),
    arrow_schema(factor("a", ordered = TRUE))
  ))
})

test_that("a difference carries a reason", {
  result <- arrow_equal(arrow_schema("i"), arrow_schema("l"))
  expect_type(attr(result, "reason"), "character")
  expect_null(attr(arrow_equal(arrow_schema("i"), arrow_schema("i")), "reason"))
})

test_that("the reason is not set on R's shared FALSE", {
  result <- arrow_equal(arrow_schema("i"), arrow_schema("l"))
  expect_false(result)
  expect_null(attributes(!TRUE))
  expect_null(attributes(identical(1, 2)))
})

test_that("metadata counts unless metadata = FALSE", {
  x <- arrow_schema("i")
  y <- x
  arrow_metadata(y) <- c(a = "1")
  expect_false(arrow_equal(x, y))
  expect_true(arrow_equal(x, y, metadata = FALSE))
  expect_error(arrow_equal(x, y, metadata = NA), class = "zuarrow_type_error")
})

test_that("arrays compare by schema and buffers", {
  expect_true(arrow_equal(test_int32(1:3), test_int32(1:3)))
  expect_false(arrow_equal(test_int32(1:3), test_int32(c(1L, 2L, 4L))))
  expect_false(arrow_equal(test_int32(1:3), test_int32(1:4)))
  expect_false(arrow_equal(
    test_int32(1:2),
    test_array("I", 2, list(NULL, writeBin(1:2, raw(), endian = "little")))
  ))
})

test_that("a malformed array is a format error, not a difference", {
  bad <- test_utf8(c(-1L, 1L), charToRaw("abc"))
  good <- test_utf8(c(0L, 1L), charToRaw("abc"))
  expect_error(arrow_equal(bad, good), class = "zuarrow_format_error")
})

test_that("streams compare batch by batch", {
  make <- function(...) test_stream("i", lapply(list(...), test_int32))
  expect_true(arrow_equal(make(1:2, 3:4), make(1:2, 3:4)))
  expect_false(arrow_equal(make(1:2, 3:4), make(1:2, 3:5)))
  expect_false(arrow_equal(make(1:2, 3:4), make(1:2)))
})

test_that("handles of different kinds are a handle error", {
  expect_error(
    arrow_equal(arrow_schema("i"), test_int32(1L)),
    class = "zuarrow_handle_error"
  )
  expect_error(arrow_equal(1, 1), class = "zuarrow_handle_error")
})

test_that("arrays compare value by value, ignoring bytes under nulls", {
  validity <- as.raw(0x05) # rows 1 and 3 valid, row 2 null
  x <- test_array(
    "i",
    3,
    list(validity, writeBin(c(1L, 7L, 3L), raw(), endian = "little")),
    null_count = 1
  )
  y <- test_array(
    "i",
    3,
    list(validity, writeBin(c(1L, 9L, 3L), raw(), endian = "little")),
    null_count = 1
  )
  expect_true(arrow_equal(x, y))

  # A null against a value is a difference.
  z <- test_int32(c(1L, 7L, 3L))
  expect_false(arrow_equal(x, z))
})

test_that("arrays with different offsets but equal values are equal", {
  x <- test_array(
    "i",
    2,
    list(NULL, writeBin(c(0L, 5L, 6L), raw(), endian = "little")),
    offset = 1
  )
  expect_true(arrow_equal(x, test_int32(5:6)))
  expect_false(arrow_equal(x, test_int32(c(5L, 7L))))
})

test_that("strings under a null slot do not count", {
  validity <- as.raw(0x01)
  x <- test_array(
    "u",
    2,
    list(
      validity,
      writeBin(c(0L, 1L, 3L), raw(), endian = "little"),
      charToRaw("abc")
    ),
    null_count = 1
  )
  y <- test_array(
    "u",
    2,
    list(
      validity,
      writeBin(c(0L, 1L, 1L), raw(), endian = "little"),
      charToRaw("a")
    ),
    null_count = 1
  )
  expect_true(arrow_equal(x, y))
  expect_false(arrow_equal(x, test_utf8(c(0L, 1L, 3L), charToRaw("abc"))))
})

test_that("nested values under a null struct row do not count", {
  schema <- test_schema(zspec("+s", children = list(zspec("i", "a"))))
  make <- function(values, validity = as.raw(0x05), null_count = 1) {
    test_array(
      schema,
      3,
      list(validity),
      null_count = null_count,
      children = list(test_array_spec(
        3,
        list(NULL, writeBin(values, raw(), endian = "little"))
      ))
    )
  }
  expect_true(arrow_equal(make(c(1L, 2L, 3L)), make(c(1L, 9L, 3L))))
  expect_false(arrow_equal(make(c(1L, 2L, 3L)), make(c(1L, 2L, 4L))))
  expect_false(arrow_equal(
    make(c(1L, 2L, 3L)),
    make(c(1L, 2L, 3L), as.raw(0x07), 0)
  ))
  expect_true(arrow_equal(
    arrow_array(list(1:2, NULL, 3L)),
    arrow_array(list(1:2, NULL, 3L))
  ))
  expect_false(arrow_equal(
    arrow_array(list(1:2, 3L)),
    arrow_array(list(1L, 2:3))
  ))
  expect_true(arrow_equal(
    arrow_array(factor(c("b", "a"))),
    arrow_array(factor(c("b", "a")))
  ))
  expect_false(arrow_equal(
    arrow_array(factor(c("b", "a"))),
    arrow_array(factor(c("a", "b"), levels = c("b", "a")))
  ))
})

test_that("a dictionary on one side only is a difference", {
  out <- arrow_equal(arrow_array(factor("a")), arrow_array(0L))
  expect_false(out)
  expect_type(attr(out, "reason"), "character")
})

test_that("run-end encoded arrays compare by the values they decode to", {
  schema <- test_schema(zspec(
    "+r",
    children = list(zspec("i", "run_ends", flags = 0L), zspec("i", "values"))
  ))
  make <- function(ends, values) {
    test_array(
      schema,
      3,
      list(),
      children = list(
        test_array_spec(length(ends), list(NULL, le_int(ends, 4L))),
        test_array_spec(length(values), list(NULL, le_int(values, 4L)))
      )
    )
  }
  # Runs of different lengths can decode to the same values.
  expect_true(arrow_equal(make(c(2, 3), c(1, 2)), make(c(1, 2, 3), c(1, 1, 2))))
  expect_false(arrow_equal(make(c(2, 3), c(1, 2)), make(c(1, 3), c(1, 2))))
  expect_false(arrow_equal(make(c(2, 3), c(1, 2)), make(c(2, 3), c(1, 5))))
})

test_that("sparse union arrays compare by type id and the chosen value", {
  schema <- test_schema(zspec(
    "+us:0,1",
    children = list(zspec("i", "a"), zspec("u", "b"))
  ))
  make <- function(ids, a, b) {
    test_array(
      schema,
      length(ids),
      list(as.raw(ids)),
      children = list(
        test_array_spec(length(a), list(NULL, le_int(a, 4L))),
        test_array_spec(
          length(b),
          list(
            NULL,
            le_int(cumsum(c(0, nchar(b))), 4L),
            charToRaw(paste(b, collapse = ""))
          )
        )
      )
    )
  }
  x <- make(c(0, 1), c(1, 2), c("x", "y"))
  expect_true(arrow_equal(x, make(c(0, 1), c(1, 2), c("x", "y"))))
  # Row 2 takes child b, so child a's second value does not count.
  expect_true(arrow_equal(x, make(c(0, 1), c(1, 9), c("x", "y"))))
  expect_false(arrow_equal(x, make(c(0, 1), c(1, 2), c("x", "z"))))
  expect_false(arrow_equal(x, make(c(0, 0), c(1, 2), c("x", "y"))))
  # A type id the schema does not list names no child.
  bad <- make(c(0, 5), c(1, 2), c("x", "y"))
  expect_error(arrow_equal(bad, bad), class = "zuarrow_format_error")
})

test_that("dense union arrays compare through their offsets", {
  schema <- test_schema(zspec(
    "+ud:0,1",
    children = list(zspec("i", "a"), zspec("u", "b"))
  ))
  make <- function(offsets, a) {
    test_array(
      schema,
      3,
      list(as.raw(c(0, 1, 0)), le_int(offsets, 4L)),
      children = list(
        test_array_spec(length(a), list(NULL, le_int(a, 4L))),
        test_array_spec(1, list(NULL, le_int(c(0, 1), 4L), charToRaw("x")))
      )
    )
  }
  x <- make(c(0, 0, 1), c(1, 2))
  expect_true(arrow_equal(x, make(c(0, 0, 1), c(1, 2))))
  expect_true(arrow_equal(x, make(c(1, 0, 2), c(0, 1, 2))))
  expect_false(arrow_equal(x, make(c(0, 0, 1), c(1, 3))))
  # An offset past its child's end.
  expect_error(
    arrow_equal(x, make(c(0, 0, 5), c(1, 2))),
    class = "zuarrow_format_error"
  )
})

test_that("large lists, list views and fixed-size lists compare by element", {
  make <- function(format, buffers, values, n = 2) {
    schema <- test_schema(zspec(format, children = list(zspec("i", "item"))))
    test_array(
      schema,
      n,
      c(list(NULL), buffers),
      children = list(
        test_array_spec(length(values), list(NULL, le_int(values, 4L)))
      )
    )
  }
  # [[1, 2], [3]]
  large <- make("+L", list(le_int(c(0, 2, 3), 8L)), 1:3)
  expect_true(arrow_equal(large, make("+L", list(le_int(c(0, 2, 3), 8L)), 1:3)))
  expect_false(arrow_equal(
    large,
    make("+L", list(le_int(c(0, 1, 3), 8L)), 1:3)
  ))
  expect_false(arrow_equal(
    large,
    make("+L", list(le_int(c(0, 2, 3), 8L)), c(1, 2, 4))
  ))

  view <- make("+vl", list(le_int(c(0, 2), 4L), le_int(c(2, 1), 4L)), 1:3)
  expect_true(arrow_equal(
    view,
    make("+vl", list(le_int(c(1, 0), 4L), le_int(c(2, 1), 4L)), c(3, 1, 2))
  ))
  expect_false(arrow_equal(
    view,
    make("+vl", list(le_int(c(0, 2), 4L), le_int(c(2, 1), 4L)), c(1, 2, 4))
  ))

  large_view <- make(
    "+vL",
    list(le_int(c(0, 2), 8L), le_int(c(2, 1), 8L)),
    1:3
  )
  expect_true(arrow_equal(
    large_view,
    make("+vL", list(le_int(c(0, 2), 8L), le_int(c(2, 1), 8L)), 1:3)
  ))
  expect_false(arrow_equal(
    large_view,
    make("+vL", list(le_int(c(0, 2), 8L), le_int(c(1, 1), 8L)), 1:3)
  ))

  fixed <- make("+w:2", list(), 1:4)
  expect_true(arrow_equal(fixed, make("+w:2", list(), 1:4)))
  expect_false(arrow_equal(fixed, make("+w:2", list(), c(1, 2, 3, 5))))
})

test_that("a dictionary index out of range is a format error", {
  make <- function(codes) {
    spec <- zspec("i")
    spec$dictionary <- zspec("u")
    test_array(
      test_schema(spec),
      length(codes),
      list(NULL, le_int(codes, 4L)),
      dictionary = test_array_spec(
        2,
        list(NULL, le_int(c(0, 1, 2), 4L), charToRaw("ab"))
      )
    )
  }
  expect_true(arrow_equal(make(c(0, 1)), make(c(0, 1))))
  expect_error(
    arrow_equal(make(c(0, 5)), make(c(0, 1))),
    class = "zuarrow_format_error"
  )
})

test_that("null arrays of one length are equal", {
  expect_true(arrow_equal(
    test_array("n", 2, list()),
    test_array("n", 2, list())
  ))
  expect_false(arrow_equal(
    test_array("n", 2, list()),
    test_array("n", 3, list())
  ))
})

test_that("streams with different schemas are not equal", {
  out <- arrow_equal(
    test_stream("i", list(test_int32(1:2))),
    test_stream("l", list())
  )
  expect_false(out)
  expect_type(attr(out, "reason"), "character")
})

test_that("bad offsets are a format error, never a crash (#102)", {
  past <- test_utf8(c(0L, 4000L, 5L), charToRaw("abcde"))
  expect_error(arrow_equal(past, past), class = "zuarrow_format_error")
  back <- test_utf8(c(0L, 3L, 1L, 5L), charToRaw("abcde"))
  expect_error(arrow_equal(back, back), class = "zuarrow_format_error")
  large <- test_array(
    "U",
    2,
    list(NULL, le_int(c(0, 4000, 5)), charToRaw("abcde"))
  )
  expect_error(arrow_equal(large, large), class = "zuarrow_format_error")
  list32 <- test_array(
    test_schema(zspec("+l", children = list(zspec("i", "item")))),
    2,
    list(NULL, le_int(c(0, 3, 1), 4L)),
    children = list(test_array_spec(3, list(NULL, le_int(1:3, 4L))))
  )
  expect_error(arrow_equal(list32, list32), class = "zuarrow_format_error")
})

test_that("a string view outside its buffers is a format error (#102)", {
  views <- c(le_int(20, 4L), charToRaw("abcd"), le_int(c(0, 0), 4L))
  bad <- test_array("vu", 1, list(NULL, views))
  expect_error(arrow_equal(bad, bad), class = "zuarrow_format_error")
  negative <- test_array("vu", 1, list(NULL, c(le_int(-1, 4L), raw(12))))
  expect_error(
    arrow_equal(negative, negative),
    class = "zuarrow_format_error"
  )
})
