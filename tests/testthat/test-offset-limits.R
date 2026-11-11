# The 2^31 - 1 thresholds of 32-bit offsets on export. Inference switches
# character to large_utf8 and a list to large_list past them; internal
# options lower both thresholds so the switch is straddled at a small
# size. The builder's refusal under an explicit 32-bit schema has no such
# option: it is reached at its real limit only where R shares one element
# many times, so the input costs no 2 GiB.

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
  withr::local_options(zuarrow.utf8_limit = 1, zuarrow.list_limit = 1)
  expect_identical(format_of_array(c("abc", "def"), schema = "u"), "string")
  l <- arrow_array(list(1:3), schema = arrow_schema(list(1:3)))
  expect_identical(format(arrow_schema(l)), "large_list<item: int32>")
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
