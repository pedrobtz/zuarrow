# The 2^31 - 1 thresholds of 32-bit offsets on export. Inference switches
# character to large_utf8 and a list to large_list past them; internal
# options lower both thresholds so the switch is straddled at a small
# size. The builder's refusal under an explicit 32-bit schema takes the
# same options, and is also reached at its real limit where R shares one
# element many times, so the input costs no 2 GiB.

test_that("inferred character switches to large_utf8 past the limit only", {
  withr::local_options(zuarrow.utf8_limit = 6)
  # 5, 6 and 7 bytes in all, over two strings; NA counts nothing.
  cases <- list(
    list(c("abc", "de", NA), "string"),
    list(c("abc", "def", NA), "string"),
    list(c("abcd", "efg", NA), "large_string")
  )
  for (case in cases) {
    x <- case[[1]]
    expect_identical(format_of_array(x), case[[2]])
    expect_identical(arrow_to_r(arrow_array(x)), x)
  }
  # Bytes, not characters: two-byte e-acute counts twice.
  expect_identical(format_of_array("\u00e9\u00e9\u00e9"), "string")
  expect_identical(format_of_array("\u00e9\u00e9\u00e9a"), "large_string")
})

test_that("an inferred list switches to large_list past the limit only", {
  withr::local_options(zuarrow.list_limit = 6)
  # 5, 6 and 7 child values in all; NULL elements count nothing.
  cases <- list(
    list(list(1:2, 3:5, NULL), "list<item: int32>"),
    list(list(1:3, 4:6, NULL), "list<item: int32>"),
    list(list(1:3, 4:7, NULL), "large_list<item: int32>")
  )
  for (case in cases) {
    x <- case[[1]]
    expect_identical(format_of_array(x), case[[2]])
    expect_identical(arrow_to_r(arrow_array(x)), x)
  }
  # A column switches as a whole, so every batch of it has one type.
  df <- data.frame(id = 1:2)
  df$l <- list(1:3, 4:7)
  bytes <- arrow_write(df, NULL, format = "stream", batch = 1)
  stream <- arrow_read(bytes, lazy = TRUE)
  expect_identical(
    format(arrow_schema(stream)),
    "struct<id: int32, l: large_list<item: int32>>"
  )
  expect_identical(arrow_to_r(stream), df)
})

test_that("each list level is measured by its own values", {
  withr::local_options(zuarrow.list_limit = 6)
  # Three outer values, but seven inner ones.
  x <- list(list(1:3, 4:7), list(), list(integer()))
  expect_identical(
    format_of_array(x),
    "list<item: large_list<item: int32>>"
  )
  expect_identical(arrow_to_r(arrow_array(x)), x)
})

test_that("an explicit 32-bit schema is kept whatever the lowered limits", {
  withr::local_options(zuarrow.utf8_limit = 6, zuarrow.list_limit = 2)
  expect_identical(format_of_array(c("abc", "def"), schema = "u"), "string")
  l <- arrow_array(list(1:3), schema = arrow_schema(list(1:3)))
  expect_identical(format(arrow_schema(l)), "large_list<item: int32>")
  withr::local_options(zuarrow.list_limit = 6)
  spec <- zspec("+l", children = list(zspec("i", "item")))
  l <- arrow_array(list(1:3, 4:6), schema = test_schema(spec))
  expect_identical(format(arrow_schema(l)), "list<item: int32>")
  expect_identical(arrow_to_r(l), list(1:3, 4:6))
})

test_that("past 2^31 - 1 bytes an explicit 32-bit schema is a limit error", {
  # 2048 copies of one 1 MiB element: 2^31 bytes, one past the limit, in
  # 1 MiB of R memory. The builder refuses before it allocates.
  r <- as.raw(rep(1, 2^20))
  blobs <- rep(list(r), 2048)
  expect_error(arrow_array(blobs, schema = "z"), class = "zuarrow_limit_error")
  # A list of raw vectors is always inferred as binary, never large_binary
  # (design section 6.2), so the same column inferred is refused too.
  expect_identical(format_of_array(list(r)), "binary")
  expect_error(arrow_array(blobs), class = "zuarrow_limit_error")
  skip_on_cran() # the UTF-8 check reads all 2 GiB
  strings <- rep(rawToChar(as.raw(rep(0x61, 2^20))), 2048)
  expect_error(
    arrow_array(strings, schema = "u"),
    class = "zuarrow_limit_error"
  )
})

# The builder's refusals under an explicit 32-bit schema, straddled through
# the same options lowered: `zuarrow.utf8_limit` for utf8 values (and a
# factor's levels), `zuarrow.binary_limit` for binary, `zuarrow.list_limit`
# for list and map. Each case holds limit - 1, limit and limit + 1.

test_that("an explicit utf8 schema refuses past the lowered limit only", {
  withr::local_options(zuarrow.utf8_limit = 6)
  cases <- list(c("abc", "de", NA), c("abc", "def", NA), c("abcd", "efg", NA))
  for (k in 1:3) {
    x <- cases[[k]]
    df <- data.frame(x = x)
    build <- list(
      function() arrow_array(x, schema = "u"),
      function() arrow_stream(x, schema = "u", batch = 3),
      function() arrow_write(arrow_stream(df, schema = struct_of("u")), NULL),
      # A factor's levels are utf8 values, as a dictionary or as strings.
      function() arrow_array(factor(x)),
      function() arrow_write(data.frame(x = factor(x)), NULL),
      function() {
        arrow_write(data.frame(x = factor(x)), NULL, dictionary = FALSE)
      }
    )
    for (f in build) {
      if (k < 3) {
        expect_no_error(f())
      } else {
        expect_error(f(), class = "zuarrow_limit_error")
      }
    }
  }
  x <- cases[[3]]
  # The limit is per batch, and large_utf8 has none.
  expect_identical(arrow_to_r(arrow_stream(x, schema = "u", batch = 1)), x)
  expect_identical(arrow_to_r(arrow_array(x, schema = "U")), x)
  expect_identical(
    arrow_to_r(arrow_array(cases[[2]], schema = "u")),
    cases[[2]]
  )
})

test_that("binary refuses past the lowered limit only, inferred or not", {
  withr::local_options(zuarrow.binary_limit = 6)
  blobs <- function(a, b) list(as.raw(seq_len(a)), as.raw(seq_len(b)), NULL)
  cases <- list(blobs(3, 2), blobs(3, 3), blobs(4, 3))
  for (k in 1:3) {
    x <- cases[[k]]
    df <- data.frame(id = 1:3)
    df$x <- x
    build <- list(
      function() arrow_array(x, schema = "z"),
      # A list of raw vectors is always inferred as binary (section 6.2).
      function() arrow_array(x),
      function() arrow_stream(x, schema = "z", batch = 3),
      function() arrow_write(df, NULL)
    )
    for (f in build) {
      if (k < 3) {
        expect_no_error(f())
      } else {
        expect_error(f(), class = "zuarrow_limit_error")
      }
    }
  }
  x <- cases[[3]]
  expect_identical(arrow_to_r(arrow_stream(x, schema = "z", batch = 1)), x)
  expect_identical(arrow_to_r(arrow_array(x, schema = "Z")), x)
  expect_identical(arrow_to_r(arrow_array(cases[[2]])), cases[[2]])
})

test_that("an explicit list or map schema refuses past the lowered limit only", {
  withr::local_options(zuarrow.list_limit = 6)
  item <- list(zspec("i", "item"))
  entries <- list(zspec(
    "+s",
    "entries",
    flags = 0L,
    children = list(zspec("u", "key", flags = 0L), zspec("i", "value"))
  ))
  pairs <- function(n) data.frame(key = letters[seq_len(n)], value = seq_len(n))
  cases <- list(
    list(1:2, 3:5, NULL),
    list(1:3, 4:6, NULL),
    list(1:3, 4:7, NULL)
  )
  maps <- list(
    list(pairs(2), pairs(3)),
    list(pairs(3), pairs(3)),
    list(pairs(4), pairs(3))
  )
  for (k in 1:3) {
    x <- cases[[k]]
    df <- data.frame(row.names = 1:3)
    df$x <- x
    m <- maps[[k]]
    build <- list(
      function() {
        arrow_array(x, schema = test_schema(zspec("+l", children = item)))
      },
      function() {
        arrow_stream(
          x,
          schema = test_schema(zspec("+l", children = item)),
          batch = 3
        )
      },
      function() {
        arrow_write(arrow_stream(df, schema = struct_of("+l", item)), NULL)
      },
      function() {
        arrow_array(m, schema = test_schema(zspec("+m", children = entries)))
      }
    )
    for (f in build) {
      if (k < 3) {
        expect_no_error(f())
      } else {
        expect_error(f(), class = "zuarrow_limit_error")
      }
    }
  }
  x <- cases[[3]]
  l32 <- test_schema(zspec("+l", children = item))
  expect_identical(arrow_to_r(arrow_stream(x, schema = l32, batch = 1)), x)
  l64 <- test_schema(zspec("+L", children = item))
  expect_identical(arrow_to_r(arrow_array(x, schema = l64)), x)
  expect_identical(
    arrow_to_r(arrow_array(cases[[2]], schema = l32)),
    cases[[2]]
  )
})

# R's own limits on import: 2^31 - 1 bytes in one string and 2^31 - 1
# levels in one factor. Internal options lower them as well:
# `zuarrow.string_limit` and `zuarrow.factor_limit`.

test_that("a string longer than the lowered R limit is refused on import", {
  withr::local_options(zuarrow.string_limit = 5)
  for (s in c("abcd", "abcde", "abcdef")) {
    ok <- nchar(s) <= 5
    df <- data.frame(x = s)
    convert <- list(
      function() arrow_to_r(arrow_array(s)),
      function() arrow_to_r(arrow_array(c(s, "x", NA))),
      function() arrow_to_r(arrow_array(s, schema = "U")),
      function() arrow_to_r(inline_views(s)),
      function() arrow_to_r(arrow_array(s), copy = FALSE)[[1]],
      function() arrow_read(arrow_write(df, NULL)),
      # A dictionary's values become a factor's levels.
      function() arrow_to_r(arrow_array(factor(s)))
    )
    for (f in convert) {
      if (ok) {
        expect_no_error(f())
      } else {
        expect_error(f(), class = "zuarrow_limit_error")
      }
    }
  }
  # The limit is per string: the column's bytes may pass it.
  x <- c("abcde", "abcde", NA)
  expect_identical(arrow_to_r(arrow_array(x)), x)
  expect_identical(arrow_to_r(arrow_array(x), copy = FALSE), x)
})

test_that("a factor of more levels than the lowered R limit is refused", {
  withr::local_options(zuarrow.factor_limit = 3)
  for (n in 2:4) {
    f <- factor(letters[seq_len(n)])
    convert <- list(
      function() arrow_to_r(arrow_array(f)),
      function() arrow_read(arrow_write(data.frame(f = f), NULL))
    )
    for (g in convert) {
      if (n <= 3) {
        expect_no_error(g())
      } else {
        expect_error(g(), class = "zuarrow_limit_error")
      }
    }
  }
  # Levels are counted over the union of every batch's dictionary.
  dict <- function(values) {
    test_dict_array(
      "u",
      c(0, 1),
      test_array_spec(2, c(list(NULL), test_string_buffers(values)))
    )
  }
  schema <- arrow_schema(dict(c("a", "b")))
  three <- test_stream(schema, list(dict(c("a", "b")), dict(c("b", "c"))))
  expect_identical(
    arrow_to_r(three),
    factor(c("a", "b", "b", "c"), levels = c("a", "b", "c"))
  )
  four <- test_stream(schema, list(dict(c("a", "b")), dict(c("c", "d"))))
  expect_error(arrow_to_r(four), class = "zuarrow_limit_error")
})
