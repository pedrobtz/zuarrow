# DuckDB as an oracle: a result read through DuckDB's Arrow export
# converts exactly or with an error. DBI, duckdb and nanoarrow are not
# dependencies; see helper-ci-oracles.R.

test_that("a BIGINT within 2^53 arrives as a double", {
  con <- local_duckdb()
  out <- duckdb_to_r(
    con,
    "SELECT 42::BIGINT AS id, -9007199254740992::BIGINT AS low, 'a' AS s"
  )
  expect_identical(out, data.frame(id = 42, low = -2^53, s = "a"))
})

test_that("a BIGINT past 2^53 is a lossy error naming zuint", {
  con <- local_duckdb()
  sql <- "SELECT 9007199254740993::BIGINT AS id"
  err <- expect_error(duckdb_to_r(con, sql), class = "zuarrow_lossy_error")
  expect_identical(err$column, "id")
  expect_identical(err$target, "zuint")
  expect_identical(
    duckdb_to_r(con, sql, lossy = "character")$id,
    structure("9007199254740993", arrow_type = "l")
  )
})

test_that("HUGEINT and UHUGEINT pass through as opaque storage", {
  con <- local_duckdb()
  out <- duckdb_to_r(
    con,
    paste(
      "SELECT 1::HUGEINT AS h,",
      "340282366920938463463374607431768211455::UHUGEINT AS u"
    )
  )
  for (name in c("h", "u")) {
    expect_identical(attr(out[[name]], "arrow_extension"), "arrow.opaque")
    expect_identical(attr(out[[name]], "arrow_width"), 16L)
  }
  expect_match(attr(out$h, "arrow_extension_metadata"), "hugeint")
  expect_match(attr(out$u, "arrow_extension_metadata"), "uhugeint")
  expect_identical(out$h[[1]], as.raw(c(1, rep(0, 15))))
  expect_identical(out$u[[1]], as.raw(rep(0xff, 16)))
})

test_that("to and lossy reach the conversion", {
  con <- local_duckdb()
  out <- duckdb_to_r(con, "SELECT 7::BIGINT AS n", to = list(n = character()))
  expect_identical(out$n, structure("7", arrow_type = "l"))
  expect_warning(
    out <- duckdb_to_r(
      con,
      "SELECT 9007199254740993::BIGINT AS n",
      lossy = "warn"
    ),
    class = "zuarrow_lossy_warning"
  )
  expect_type(out$n, "double")
})

test_that("an empty result keeps its columns", {
  con <- local_duckdb()
  out <- duckdb_to_r(con, "SELECT 1::INTEGER AS x WHERE false")
  expect_identical(out, data.frame(x = integer()))
})

test_that("a registration makes DuckDB's BIGINT exact", {
  # A test-only registration stands in for zuint's, which does not exist
  # yet (helper-registry.R).
  local_registration("l", to = as_text_int64)
  con <- local_duckdb()
  out <- duckdb_to_r(con, "SELECT 9007199254740993::BIGINT AS i")
  expect_identical(out$i, structure("9007199254740993", class = "fake_int64"))
})
