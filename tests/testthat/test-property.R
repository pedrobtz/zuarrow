# Property tests (design section 9): for every built-in exact type, random
# values with nulls round-trip identically, arrow_equal() holds and full
# validation passes.

test_that("every exact type round-trips with nulls", {
  withr::local_seed(20261021)
  for (kind in c("logical", "integer", "double", "character", "Date", "blob")) {
    for (n in c(1L, 7L, 100L)) {
      x <- random_values(kind, max(n, 3L))
      array <- arrow_array(x)
      expect_identical(arrow_to_r(array), x, info = kind)
      expect_true(arrow_equal(array, arrow_array(x)), info = kind)
      expect_true(arrow_validate(array, "full"), info = kind)
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
    t = random_values("Date", n)
  )
  df$b <- random_values("blob", n)
  for (batch in c(1L, 7L, 50L, 1000L)) {
    expect_identical(as.data.frame(arrow_stream(df, batch = batch)), df)
  }
  expect_true(arrow_validate(arrow_stream(df, batch = 9L), "full"))
})
