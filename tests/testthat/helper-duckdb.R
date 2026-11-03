# A DuckDB connection for the test, closed when it ends. Skips without the
# engine packages arrow_duckdb() needs. One thread, so DuckDB starts no
# worker threads: their thread-local storage is a "possibly lost" block
# under valgrind, which fails the valgrind job.
local_duckdb <- function(.env = parent.frame()) {
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("nanoarrow")
  con <- DBI::dbConnect(duckdb::duckdb(
    shared_home = FALSE,
    config = list(threads = "1")
  ))
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = .env)
  con
}
