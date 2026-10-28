# Property tests (design section 9): for every built-in exact type, random
# values with nulls round-trip identically, arrow_equal() holds and full
# validation passes.

test_that("every exact type round-trips with nulls", {
  withr::local_seed(20261021)
  kinds <- c(
    "logical",
    "integer",
    "double",
    "character",
    "Date",
    "blob",
    "factor",
    "ordered",
    "list",
    "frames",
    "struct"
  )
  for (kind in kinds) {
    for (n in c(1L, 2L, 7L, 100L)) {
      x <- random_values(kind, n)
      info <- paste(kind, n)
      array <- arrow_array(x)
      expect_identical(arrow_to_r(array), x, info = info)
      expect_true(arrow_equal(array, arrow_array(x)), info = info)
      expect_true(arrow_validate(array, "full"), info = info)
    }
  }
})

test_that("a data frame of every exact type round-trips through a stream", {
  withr::local_seed(20261022)
  n <- 50L
  df <- data.frame(
    l = random_values("logical", n),
    i = random_values("integer", n),
    d = random_values("double", n),
    s = random_values("character", n),
    t = random_values("Date", n),
    f = random_values("factor", n),
    o = random_values("ordered", n)
  )
  df$b <- random_values("blob", n)
  df$list <- random_values("list", n)
  df$frames <- random_values("frames", n)
  df$struct <- random_values("struct", n)
  for (batch in c(1L, 7L, 50L, 1000L)) {
    expect_identical(as.data.frame(arrow_stream(df, batch = batch)), df)
  }
  expect_true(arrow_validate(arrow_stream(df, batch = 9L), "full"))
  expect_identical(arrow_read(arrow_write(df, NULL, batch = 9L)), df)
})
