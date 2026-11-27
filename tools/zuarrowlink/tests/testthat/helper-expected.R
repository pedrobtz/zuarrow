# The eight columns both the builders and the IPC files hold, as
# stream_columns() returns them: l, d and t as doubles of their integer
# values (days and microseconds). tools/make-consumer-fixture.R writes the
# files from the same values.
expected_columns <- function() {
  list(
    b = c(TRUE, NA, FALSE, TRUE),
    i = c(1L, NA, -2147483647L, 42L),
    l = c(2^53, NA, -1, 0),
    g = c(1.5, NA, -Inf, 0.25),
    u = c("a", NA, "\u00e9", ""),
    z = list(as.raw(1:3), NULL, raw(), as.raw(255)),
    d = c(0, NA, 20784, -1),
    t = c(0, NA, 1764201600500000, -1)
  )
}

expected_formats <- c("b", "i", "l", "g", "u", "z", "tdD", "tsu:UTC")

extdata <- function(name) system.file("extdata", name, package = "zuarrowlink")

# zuarrow is the oracle where it is installed: tools/ci/consumer.sh
# installs it and sets ZUARROWLINK_ORACLE, so there a missing zuarrow
# fails; the run with zuarrow moved away skips these.
skip_without_zuarrow <- function() {
  if (!requireNamespace("zuarrow", quietly = TRUE)) {
    if (nzchar(Sys.getenv("ZUARROWLINK_ORACLE"))) {
      stop("ZUARROWLINK_ORACLE is set but zuarrow is not installed")
    }
    testthat::skip("zuarrow is not installed")
  }
}

# A data frame of the expected columns as arrow_read() gives them.
as_r <- function(cols) {
  df <- as.data.frame(cols[c("b", "i", "l", "g", "u")])
  df$z <- cols$z
  df$d <- as.Date(cols$d)
  df$t <- as.POSIXct(cols$t / 1e6, tz = "UTC")
  df
}
