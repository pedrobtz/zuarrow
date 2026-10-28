# Oracle 2 (design section 9): ClusterFuzz test cases that crashed earlier
# readers. Each must be refused cleanly, never crash, with the outcome
# crash-expected.csv pins for it.

test_that("every crash case has its expected outcome", {
  dir <- fixtures_dir()
  files <- c(
    list.files(file.path(dir, "arrow-ipc-file"), full.names = TRUE),
    list.files(file.path(dir, "arrow-ipc-stream"), full.names = TRUE)
  )
  files <- files[!dir.exists(files)]
  expect_gt(length(files), 100)
  expected <- crash_expected()
  expected <- expected[!startsWith(expected$file, "data/"), ]
  relative <- substring(files, nchar(dir) + 2L)
  expect_setequal(relative, expected$file)
  for (k in seq_len(nrow(expected))) {
    path <- file.path(dir, expected$file[[k]])
    expect_identical(
      crash_outcome(path),
      expected$expect[[k]],
      info = basename(path)
    )
  }
})

test_that("a file whose footer and schema message disagree is refused", {
  # A ClusterFuzz case that libarrow reads through its footer's schema; the
  # schema message names one field differently.
  path <- file.path(
    fixtures_dir(),
    "arrow-ipc-file",
    "clusterfuzz-testcase-minimized-arrow-ipc-file-fuzz-6088759971217408"
  )
  expect_error(arrow_read(path), class = "zuarrow_format_error")
  # The same rule on a file zuarrow wrote: rename the field in one copy.
  bytes <- arrow_write(data.frame(xQx = 1L), NULL)
  at <- bytes_at(bytes, "xQx")
  expect_length(at, 2L)
  bytes[at[[2]] + 1L] <- charToRaw("R")
  expect_error(arrow_read(bytes), class = "zuarrow_format_error")
  expect_identical(arrow_read(arrow_write(data.frame(xQx = 1L), NULL))$xQx, 1L)
})
