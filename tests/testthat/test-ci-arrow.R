# libarrow as an oracle through the arrow R package (design section 9).
# arrow is not a dependency: this file is left out of the package tarball
# (.Rbuildignore) and runs from the source tree, in CI by oracles.yaml.

# From test-oracle-golden.R.
test_that("libarrow decodes the golden files to the same values", {
  skip_without_oracle("arrow")
  skip_without_oracle("nanoarrow")
  skip_if_not(
    arrow::codec_is_available("zstd") && arrow::codec_is_available("lz4_frame"),
    "arrow was built without its codecs"
  )
  # Cases libarrow itself cannot read, as "version case". None today; a
  # case added here is skipped, and one that reads again fails.
  unreadable <- character()
  versions <- c(
    "0.14.1",
    "0.17.1",
    "1.0.0-littleendian",
    "2.0.0-compression",
    "4.0.0-shareddict",
    "cpp-21.0.0"
  )
  # zuarrow's reading of every version is the test above; under gctorture
  # this one adds only arrow's, so the version with the most cases is enough.
  if (under_gctorture()) {
    versions <- "cpp-21.0.0"
  }
  for (version in versions) {
    cases <- golden_cases(version)
    for (case in names(cases)) {
      if (no_r_form(case)) {
        next
      }
      label <- paste(version, case)
      path <- paste0(cases[[case]], ".arrow_file")
      table <- tryCatch(
        arrow::read_ipc_file(path, as_data_frame = FALSE),
        error = function(e) NULL
      )
      if (label %in% unreadable) {
        expect_null(table, info = label)
        next
      }
      if (is.null(table)) {
        fail(paste("libarrow cannot read", label))
        next
      }
      theirs <- arrow_to_r(
        nanoarrow::as_nanoarrow_array_stream(table),
        lossy = "character"
      )
      expect_identical(read_golden(path), theirs, info = label)
    }
  }
})

# From test-read.R.
test_that("arrow reads what arrow wrote, the same way", {
  skip_without_oracle("arrow")
  # A minimal arrow build has no zstd: the portability gap D2 removes.
  skip_if_not(arrow::codec_is_available("zstd"), "arrow was built without zstd")
  path <- test_data("basic-zstd.arrow")
  ours <- without_metadata(arrow_read(path))
  theirs <- as.data.frame(arrow::read_feather(path))
  expect_identical(ours, theirs)
})

# From test-write.R.
# Oracle 4 (design section 9): arrow reads what zuarrow writes, at every
# option, and zuarrow reads what arrow writes.
test_that("arrow reads what arrow_write() writes", {
  skip_without_oracle("arrow")
  skip_if_not(
    arrow::codec_is_available("zstd") && arrow::codec_is_available("lz4_frame"),
    "arrow was built without its codecs"
  )
  df <- basic_df()
  for (compression in c("none", "lz4", "zstd")) {
    file <- arrow_write(df, NULL, compression = compression)
    expect_identical(
      as.data.frame(arrow::read_feather(file)),
      df,
      info = compression
    )
    stream <- arrow_write(
      df,
      NULL,
      format = "stream",
      compression = compression
    )
    expect_identical(
      as.data.frame(arrow::read_ipc_stream(stream)),
      df,
      info = compression
    )
  }
})

# From test-write.R.
test_that("arrow_read() reads what arrow writes, at every compression", {
  skip_without_oracle("arrow")
  skip_if_not(
    arrow::codec_is_available("zstd") && arrow::codec_is_available("lz4_frame"),
    "arrow was built without its codecs"
  )
  df <- basic_df()
  for (compression in c("uncompressed", "lz4", "zstd")) {
    path <- withr::local_tempfile(fileext = ".arrow")
    arrow::write_feather(df, path, compression = compression)
    expect_identical(without_metadata(arrow_read(path)), df, info = compression)
  }
})
