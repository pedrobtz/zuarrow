#' Run a DuckDB query and receive the result exactly
#'
#' `arrow_duckdb()` runs `sql` on a DuckDB connection and returns the result
#' as a data frame. The rows travel as an Arrow stream, so every column is
#' converted as [arrow_to_r()] converts it: exactly, or with an error that
#' names the column.
#'
#' The query runs with DuckDB's `arrow_lossless_conversion` setting on. Then
#' `HUGEINT` and `UHUGEINT` arrive as the `arrow.opaque` extension over
#' `fixed_size_binary(16)`, not as a `decimal128(38, 0)` that cannot be told
#' from a real decimal. Without a registration for them, they pass through
#' as a list of 16-byte raw vectors that keeps the extension in its
#' attributes. The setting is put back as it was when the call returns.
#'
#' A `BIGINT` whose values all lie within ±2^53 becomes a double. A value
#' beyond that is a `zuarrow_lossy_error` naming 'zuint' under the default
#' policy, as for any `int64` column. A package that registers exact
#' classes with [arrow_register()] makes such columns exact.
#'
#' It needs the 'DBI', 'duckdb' (1.5.4 or later) and 'nanoarrow' packages.
#'
#' @param con A connection from `DBI::dbConnect(duckdb::duckdb())`.
#' @param sql The query, a single string.
#' @inheritParams arrow_to_r
#' @returns A data frame.
#' @seealso [arrow_to_r()] for the conversion and its policies.
#' @export
#' @examplesIf all(vapply(c("DBI", "duckdb", "nanoarrow"), requireNamespace, NA, quietly = TRUE))
#' con <- DBI::dbConnect(duckdb::duckdb())
#' arrow_duckdb(con, "SELECT 42::BIGINT AS id, 'a' AS label")
#'
#' big <- "SELECT 9007199254740993::BIGINT AS id"
#' try(arrow_duckdb(con, big))
#' arrow_duckdb(con, big, lossy = "character")
#' DBI::dbDisconnect(con, shutdown = TRUE)
arrow_duckdb <- function(con, sql, to = NULL, lossy = zar_lossy_policies) {
  call <- sys.call()
  lossy <- zar_arg_match(lossy, zar_lossy_policies, "lossy", call)
  for (package in c("DBI", "duckdb", "nanoarrow")) {
    if (!zar_installed(package)) {
      zar_abort(
        "dependency",
        sprintf("arrow_duckdb() needs the %s package.", package),
        call = call,
        package = package
      )
    }
  }
  if (!inherits(con, "duckdb_connection")) {
    zar_abort(
      "type",
      "`con` must be a connection from `DBI::dbConnect(duckdb::duckdb())`.",
      call = call
    )
  }
  if (!is.character(sql) || length(sql) != 1L || is.na(sql)) {
    zar_abort("type", "`sql` must be a single string.", call = call)
  }

  setting <- "SELECT current_setting('arrow_lossless_conversion') AS v"
  before <- isTRUE(as.logical(DBI::dbGetQuery(con, setting)$v))
  DBI::dbExecute(con, "SET arrow_lossless_conversion = true")
  on.exit(
    DBI::dbExecute(
      con,
      sprintf(
        "SET arrow_lossless_conversion = %s",
        if (before) "true" else "false"
      )
    ),
    add = TRUE
  )
  res <- DBI::dbSendQueryArrow(con, sql)
  # Cleared before the setting is put back.
  on.exit(DBI::dbClearResult(res), add = TRUE, after = FALSE)
  # DBI's default methods would go through a data frame and round a BIGINT
  # before zuarrow saw it; only DuckDB's own Arrow result is exact.
  if (!inherits(res, "duckdb_result_arrow")) {
    zar_abort(
      "dependency",
      "arrow_duckdb() needs duckdb 1.5.4 or later.",
      call = call,
      package = "duckdb"
    )
  }
  # arrow_to_r()'s stream path, so its conditions name this call.
  stream <- DBI::dbFetchArrow(res)
  batches <- zar_stream_batches(stream, call)
  zar_convert(batches, arrow_schema(stream), to, lossy, call)
}

zar_installed <- function(package) {
  requireNamespace(package, quietly = TRUE)
}
