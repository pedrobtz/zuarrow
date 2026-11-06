# The oracle packages (arrow, nanoarrow, DBI, duckdb) are not dependencies
# of zuarrow. The files named *-ci-* use them, and .Rbuildignore leaves
# those files out of the package tarball, so R CMD check and CRAN never see
# them. They run from the source tree: in CI through oracles.yaml, which
# sets ZUARROW_ORACLES=true and makes a missing oracle a failure, and
# locally through devtools::test(), which skips what is not installed.
skip_without_oracle <- function(package) {
  if (identical(Sys.getenv("ZUARROW_ORACLES"), "true")) {
    if (!requireNamespace(package, quietly = TRUE)) {
      stop(sprintf("The oracle package %s is not installed.", package))
    }
    return(invisible())
  }
  skip_on_cran()
  skip_if_not_installed(package)
}

# arrow, with the codecs a test needs. A minimal arrow build lacks them:
# skipped locally, a failure under ZUARROW_ORACLES=true, where a codec-less
# arrow would silently drop the libarrow oracle.
skip_without_arrow_codecs <- function(codecs = c("zstd", "lz4_frame")) {
  skip_without_oracle("arrow")
  missing <- codecs[!vapply(codecs, arrow::codec_is_available, logical(1))]
  if (length(missing) == 0L) {
    return(invisible())
  }
  message <- sprintf(
    "arrow was built without %s.",
    paste(missing, collapse = " and ")
  )
  if (identical(Sys.getenv("ZUARROW_ORACLES"), "true")) {
    stop(message)
  }
  skip(message)
}
