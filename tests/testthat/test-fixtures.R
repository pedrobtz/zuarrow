test_that("a fixture download is retried after a transient failure (#151)", {
  dest <- withr::local_tempfile()
  calls <- 0L
  flaky <- function(url, destfile, ...) {
    calls <<- calls + 1L
    writeBin(as.raw(seq_len(calls)), destfile)
    if (calls < 3L) {
      stop("connection reset")
    }
    0L
  }
  pauses <- numeric()
  expect_true(fetch_file("u", dest, download = flaky, pause = function(s) {
    pauses <<- c(pauses, s)
  }))
  expect_identical(calls, 3L)
  expect_identical(pauses, c(1, 2))
  # Only the complete download is in place, and no partial file is left.
  expect_identical(readBin(dest, "raw", 10), as.raw(1:3))
  expect_false(file.exists(paste0(dest, ".part")))
})

test_that("a fixture download that keeps failing reports failure", {
  dest <- withr::local_tempfile()
  calls <- 0L
  broken <- function(url, destfile, ...) {
    calls <<- calls + 1L
    writeBin(as.raw(1), destfile)
    warning("HTTP status was '404 Not Found'")
  }
  expect_false(fetch_file("u", dest, download = broken, pause = function(s) {
    NULL
  }))
  expect_identical(calls, 4L)
  expect_false(file.exists(dest))
  expect_false(file.exists(paste0(dest, ".part")))
})
