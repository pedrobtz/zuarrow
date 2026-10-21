#!/usr/bin/env Rscript
# Writes the small IPC files tests/testthat/data/ holds, with the arrow
# package, so the reader's tests run on every leg, the one without
# suggested packages included. Run from the package root after changing
# them; the files are committed.
stopifnot(requireNamespace("arrow", quietly = TRUE))
out <- "tests/testthat/data"
dir.create(out, showWarnings = FALSE)
df <- data.frame(
  i = c(1L, NA, 3L, 4L),
  d = c(1.5, NA, -2, 1e300),
  s = c("a", NA, "café", ""),
  f = factor(c("x", "y", NA, "x")),
  dt = as.Date("2026-10-21") + c(0L, NA, 2L, 3L),
  stringsAsFactors = FALSE
)
# The data frame itself, for the tests to compare against.
saveRDS(df, file.path(out, "basic.rds"), version = 2)
table <- arrow::arrow_table(df)
table$metadata <- list(origin = "zuarrow tests")
arrow::write_feather(
  table,
  file.path(out, "basic.arrow"),
  compression = "uncompressed"
)
arrow::write_feather(
  table,
  file.path(out, "basic-lz4.arrow"),
  compression = "lz4"
)
arrow::write_feather(
  table,
  file.path(out, "basic-zstd.arrow"),
  compression = "zstd"
)
arrow::write_ipc_stream(table, file.path(out, "basic.arrows"))
arrow::write_ipc_stream(
  table,
  file.path(out, "basic-zstd.arrows"),
  compression = "zstd"
)
# Two record batches.
batches <- arrow::RecordBatchReader$create(
  arrow::record_batch(df[1:2, ]),
  arrow::record_batch(df[3:4, ])
)
arrow::write_ipc_stream(
  batches$read_table(),
  file.path(out, "two-batches.arrows")
)
