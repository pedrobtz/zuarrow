# The committed IPC files of tools/make-test-data.R.
test_data <- function(name) test_path("data", name)

basic_df <- function() readRDS(test_data("basic.rds"))

without_metadata <- function(df) {
  attr(df, "arrow_metadata") <- NULL
  df
}

# The fixed input of the determinism test (design section 6.8). Every value
# must be the same double on every platform before zuarrow sees it: R's
# parser rounds a literal such as 1e300 differently where long double is no
# wider than double (arm64 macOS, valgrind), so the large value is 2^1000,
# which is exact.
determinism_df <- function() {
  data.frame(
    i = c(1L, NA, 3L, -4L),
    d = c(1.5, NA, -2, 2^1000),
    s = c("a", NA, "café", ""),
    f = factor(c("x", "y", NA, "x")),
    dt = as.Date("2026-10-21") + c(0L, NA, 2L, 3L)
  )
}

md5_of <- function(bytes) {
  path <- withr::local_tempfile()
  writeBin(bytes, path)
  unname(tools::md5sum(path))
}
