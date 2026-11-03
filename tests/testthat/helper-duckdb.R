# A DuckDB connection for the test, closed when it ends. Skips without the
# engine packages arrow_duckdb() needs, and on CRAN: DuckDB keeps a scheduler
# thread for the life of the process, which valgrind reports as "possibly
# lost", and duckdb does not run its own engine tests on CRAN either. CI runs
# them, with that record suppressed (tools/valgrind.supp).
local_duckdb <- function(.env = parent.frame()) {
  skip_on_cran()
  skip_if_not_installed("DBI")
  skip_if_not_installed("duckdb")
  skip_if_not_installed("nanoarrow")
  con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = .env)
  con
}
