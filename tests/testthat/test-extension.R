# Extension types, design section 6.6.

test_that("an unregistered extension converts as storage and keeps its name", {
  array <- test_array(
    ext_schema("w:16", "arrow.uuid"),
    1,
    list(NULL, as.raw(1:16))
  )
  out <- arrow_to_r(array)
  expect_identical(unclass(out)[[1]], as.raw(1:16))
  expect_identical(attr(out, "arrow_extension"), "arrow.uuid")
})

test_that("extension metadata is kept, as text or raw", {
  text <- test_array(
    ext_schema("u", "my.json", charToRaw("{\"v\":1}")),
    1,
    list(NULL, le_int(c(0, 2), 4L), charToRaw("{}"))
  )
  out <- arrow_to_r(text)
  expect_identical(attr(out, "arrow_extension_metadata"), "{\"v\":1}")
  binary <- test_array(
    ext_schema("i", "my.ext", as.raw(c(0, 255))),
    1,
    list(NULL, le_int(1, 4L))
  )
  expect_identical(
    attr(arrow_to_r(binary), "arrow_extension_metadata"),
    as.raw(c(0, 255))
  )
})

test_that("export restores the extension field exactly", {
  array <- test_array(
    ext_schema("u", "my.json", charToRaw("{\"v\":1}")),
    2,
    list(NULL, le_int(c(0, 2, 4), 4L), charToRaw("{}[]"))
  )
  back <- arrow_array(arrow_to_r(array))
  expect_true(arrow_equal(back, array))
})

test_that("arrow.bool8 reads as logical and writes back as bool8", {
  array <- test_array(
    ext_schema("c", "arrow.bool8"),
    3,
    list(as.raw(0x05), as.raw(c(0, 0, 7))),
    null_count = 1
  )
  out <- arrow_to_r(array)
  expect_identical(as.vector(out), c(FALSE, NA, TRUE))
  back <- arrow_array(out)
  expect_identical(format_of(arrow_schema(back)), "c")
  expect_identical(
    arrow_metadata(back)[["ARROW:extension:name"]],
    "arrow.bool8"
  )
  expect_identical(as.vector(arrow_to_r(back)), c(FALSE, NA, TRUE))
})

test_that("field metadata becomes arrow_field_metadata and back", {
  df <- data.frame(x = 1:2)
  attr(df$x, "arrow_field_metadata") <- c(unit = "kg")
  array <- arrow_array(df)
  out <- arrow_to_r(array)
  expect_identical(attr(out$x, "arrow_field_metadata"), c(unit = "kg"))
  expect_true(arrow_equal(arrow_array(out), array))
})
