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
