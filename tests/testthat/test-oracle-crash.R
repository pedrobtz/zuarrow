# Oracle 2 (design section 9): ClusterFuzz test cases that crashed earlier
# readers. Each must be refused cleanly, never crash.

test_that("every crash case is a format or limit error, or reads", {
  dir <- fixtures_dir()
  files <- c(
    list.files(file.path(dir, "arrow-ipc-file"), full.names = TRUE),
    list.files(file.path(dir, "arrow-ipc-stream"), full.names = TRUE)
  )
  files <- files[!dir.exists(files)]
  expect_gt(length(files), 100)
  for (f in files) {
    result <- tryCatch(
      arrow_read(f, lossy = "allow"),
      zuarrow_error = function(e) e
    )
    ok <- is.data.frame(result) ||
      inherits(
        result,
        c(
          "zuarrow_format_error",
          "zuarrow_limit_error",
          "zuarrow_codec_error",
          "zuarrow_lossy_error"
        )
      )
    expect_true(ok, info = basename(f))
  }
})
