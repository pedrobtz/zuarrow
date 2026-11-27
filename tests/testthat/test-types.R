test_that("arrow_types() lists the built-in table", {
  types <- arrow_types()
  expect_s3_class(types, "data.frame")
  expect_named(
    types,
    c("arrow", "format", "r", "exact", "lossy_r", "exact_with", "from_r")
  )
  expect_true(all(
    c("int64", "uint32", "date32", "interval") %in%
      unlist(strsplit(types$arrow, ", "))
  ))
  expect_identical(types$exact_with[types$arrow == "int64"], "zuint")
})

test_that("arrow_types() says which R values write each type", {
  types <- arrow_types()
  from_r <- stats::setNames(types$from_r, types$arrow)
  expect_match(from_r[["int64"]], "integer64")
  expect_identical(from_r[["interval"]], "text")
  expect_identical(from_r[["dense_union, sparse_union"]], "")
  # Each type whose row names an R value is written from it.
  df <- data.frame(id = 1:2)
  df$m <- structure(c("1M", NA), arrow_type = "tiM")
  df$t <- structure(c("01:02:03", NA), arrow_type = "tts")
  types <- c(id = "s", h = "e", v = "vu", z = "vz", d = "tdm")
  df$h <- c(0.5, NA)
  df$v <- c("a", NA)
  df$z <- list(as.raw(1), NULL)
  df$d <- as.Date(c("2026-11-26", NA))
  expect_identical(
    format(arrow_schema(arrow_array(df, schema = types))),
    paste0(
      "struct<id: int16, m: interval_months, t: time32('s'), h: half_float, ",
      "v: string_view, z: binary_view, d: date64>"
    )
  )
})
