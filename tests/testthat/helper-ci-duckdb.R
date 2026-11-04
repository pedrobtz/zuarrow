# A DuckDB connection for the test, closed when it ends.
local_duckdb <- function(.env = parent.frame()) {
  skip_without_oracle("DBI")
  skip_without_oracle("duckdb")
  skip_without_oracle("nanoarrow")
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = .env)
  con
}

# A query's result through DuckDB's Arrow export, converted by zuarrow.
# arrow_lossless_conversion makes DuckDB export HUGEINT and UHUGEINT as
# arrow.opaque rather than as a rounded decimal.
duckdb_to_r <- function(con, sql, ...) {
  DBI::dbExecute(con, "SET arrow_lossless_conversion = true")
  arrow_to_r(DBI::dbGetQueryArrow(con, sql), ...)
}
