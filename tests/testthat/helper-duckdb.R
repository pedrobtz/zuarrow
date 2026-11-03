# A DuckDB connection for the test, closed when it ends. Skips without the
# engine packages arrow_duckdb() needs.
local_duckdb <- function(.env = parent.frame()) {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("nanoarrow")
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = .env)
  con
}
