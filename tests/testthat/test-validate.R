test_that("a valid array passes every level", {
  array <- test_int32(c(1L, 2L, 3L))
  for (level in c("minimal", "default", "full")) {
    expect_true(arrow_validate(array, level))
  }
  expect_true(arrow_validate(test_utf8(c(0L, 1L, 3L), charToRaw("abc"))))
})

test_that("a negative first offset fails from the default level", {
  bad <- test_utf8(c(-1L, 2L), charToRaw("abc"))
  expect_true(arrow_validate(bad, "minimal"))
  expect_error(arrow_validate(bad, "default"), class = "zuarrow_format_error")
})

test_that("decreasing offsets fail at the full level, which reads them", {
  bad <- test_utf8(c(0L, 3L, 1L), charToRaw("abc"))
  expect_true(arrow_validate(bad, "default"))
  expect_error(arrow_validate(bad, "full"), class = "zuarrow_format_error")
})

test_that("invalid UTF-8 fails at the full level only", {
  bad <- test_utf8(c(0L, 2L), as.raw(c(0xc3, 0x28)))
  expect_true(arrow_validate(bad, "default"))
  expect_error(arrow_validate(bad, "full"), class = "zuarrow_format_error")
})

test_that("the UTF-8 check is strict", {
  check <- function(bytes) {
    array <- test_utf8(c(0L, length(bytes)), as.raw(bytes))
    tryCatch(arrow_validate(array, "full"), zuarrow_format_error = function(e) {
      FALSE
    })
  }
  expect_true(check(c(0x61, 0xc3, 0xa9))) # a, e-acute
  expect_true(check(c(0xf0, 0x9f, 0x98, 0x80))) # U+1F600
  expect_false(check(c(0xc0, 0xaf))) # overlong '/'
  expect_false(check(c(0xe0, 0x80, 0xaf))) # overlong, three bytes
  expect_false(check(c(0xed, 0xa0, 0x80))) # surrogate U+D800
  expect_false(check(c(0xf4, 0x90, 0x80, 0x80))) # above U+10FFFF
  expect_false(check(c(0xe2, 0x82))) # truncated
  expect_false(check(0xff))
})

test_that("a null string is not read for UTF-8", {
  bad_but_null <- test_array(
    "u",
    length = 1,
    null_count = 1,
    buffers = list(
      as.raw(0),
      writeBin(c(0L, 1L), raw(), endian = "little"),
      as.raw(0xff)
    )
  )
  expect_true(arrow_validate(bad_but_null, "full"))
})

test_that("invalid UTF-8 in a child or a dictionary is found", {
  df_schema <- arrow_schema(data.frame(s = "a"))
  bad_child <- test_array(
    df_schema,
    length = 1,
    buffers = list(NULL),
    children = list(test_array_spec(
      length = 1,
      buffers = list(
        NULL,
        writeBin(c(0L, 1L), raw(), endian = "little"),
        as.raw(0xff)
      )
    ))
  )
  expect_true(arrow_validate(bad_child, "default"))
  expect_error(
    arrow_validate(bad_child, "full"),
    class = "zuarrow_format_error"
  )
})

test_that("a dictionary index out of range fails at the full level", {
  schema <- arrow_schema(factor("a"))
  bad <- test_array(
    schema,
    length = 2,
    buffers = list(NULL, writeBin(c(0L, 5L), raw(), endian = "little")),
    dictionary = test_array_spec(
      length = 1,
      buffers = list(
        NULL,
        writeBin(c(0L, 1L), raw(), endian = "little"),
        charToRaw("a")
      )
    )
  )
  expect_true(arrow_validate(bad, "default"))
  expect_error(arrow_validate(bad, "full"), class = "zuarrow_format_error")
})

test_that("a negative length fails at the minimal level", {
  bad <- test_array("i", length = -1, buffers = list(NULL, raw()))
  expect_error(arrow_validate(bad, "minimal"), class = "zuarrow_format_error")
})

test_that("a stream is validated batch by batch", {
  good <- test_stream(
    "u",
    list(
      test_utf8(c(0L, 1L), charToRaw("a")),
      test_utf8(c(0L, 2L), charToRaw("bc"))
    )
  )
  expect_true(arrow_validate(good))

  bad <- test_stream(
    "u",
    list(
      test_utf8(c(0L, 1L), charToRaw("a")),
      test_utf8(c(0L, 2L), as.raw(c(0xc3, 0x28)))
    )
  )
  expect_error(arrow_validate(bad), class = "zuarrow_format_error")
})

test_that("a schema handle validates when it is live", {
  expect_true(arrow_validate(arrow_schema("i")))
})

test_that("an unknown level is a type error", {
  expect_error(
    arrow_validate(test_int32(1L), "strict"),
    class = "zuarrow_type_error"
  )
  expect_true(arrow_validate(test_int32(1L), "minimal"))
})
