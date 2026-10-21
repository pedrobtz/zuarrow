# Oracle 1 (design section 9): apache/arrow-testing's golden files. For
# every little-endian case the file and the stream decode to the same R
# value, read with lossy = "character" so the cases that need zuint,
# decimal or zutempo are compared exactly as text; where the arrow package
# is installed, both equal libarrow's decoding of the same file through
# the same conversion. Unions and intervals have no R form, and the
# big-endian directory is refused (D13).

test_that("every little-endian golden case decodes the same from file and stream", {
  versions <- c(
    "0.14.1",
    "0.17.1",
    "1.0.0-littleendian",
    "2.0.0-compression",
    "4.0.0-shareddict",
    "cpp-21.0.0"
  )
  for (version in versions) {
    cases <- golden_cases(version)
    for (case in names(cases)) {
      label <- paste(version, case)
      from_file <- read_golden(paste0(cases[[case]], ".arrow_file"))
      from_stream <- read_golden(paste0(cases[[case]], ".stream"))
      if (no_r_form(case)) {
        expect_s3_class(from_file, "zuarrow_lossy_error")
        expect_s3_class(from_stream, "zuarrow_lossy_error")
        next
      }
      expect_s3_class(from_file, "data.frame")
      expect_identical(from_file, from_stream, info = label)
    }
  }
})

test_that("the view and run-end encoded cases of cpp-21.0.0 decode", {
  cases <- golden_cases("cpp-21.0.0")
  for (case in c(
    "generated_binary_view",
    "generated_list_view",
    "generated_run_end_encoded"
  )) {
    expect_s3_class(
      read_golden(paste0(cases[[case]], ".arrow_file")),
      "data.frame"
    )
  }
})

test_that("libarrow decodes the golden files to the same values", {
  skip_if_not_installed("arrow")
  for (version in c("1.0.0-littleendian", "2.0.0-compression", "cpp-21.0.0")) {
    cases <- golden_cases(version)
    for (case in names(cases)) {
      if (no_r_form(case)) {
        next
      }
      path <- paste0(cases[[case]], ".arrow_file")
      theirs <- tryCatch(
        arrow_to_r(
          nanoarrow::as_nanoarrow_array_stream(arrow::read_ipc_file(
            path,
            as_data_frame = FALSE
          )),
          lossy = "character"
        ),
        error = function(e) NULL
      )
      if (is.null(theirs)) {
        next
      }
      expect_identical(read_golden(path), theirs, info = paste(version, case))
    }
  }
})

test_that("big-endian input is a format error", {
  cases <- golden_cases("1.0.0-bigendian")
  for (case in names(cases)) {
    expect_error(
      arrow_read(paste0(cases[[case]], ".arrow_file")),
      class = "zuarrow_format_error",
      info = case
    )
    expect_error(
      arrow_read(paste0(cases[[case]], ".stream")),
      class = "zuarrow_format_error",
      info = case
    )
  }
})
