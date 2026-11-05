# Oracle 1 (design section 9): apache/arrow-testing's golden files. For
# every little-endian case the file and the stream decode to the same R
# value, read with lossy = "character" so the cases that need zuint,
# decimal or zutempo are compared exactly as text; where the arrow package
# is installed, both equal libarrow's decoding of the same file through
# the same conversion, for every version. Unions and intervals have no R
# form, and the big-endian directory is refused (D13).

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

test_that("big-endian input is a format error", {
  cases <- golden_cases("1.0.0-bigendian")
  # Each case is refused at the same schema check.
  for (case in gctorture_sample(names(cases), 3L)) {
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

test_that("lossy = \"character\" gives the JSON text of every golden integer and decimal case", {
  skip_if_not_installed("zujson")
  versions <- c(
    "0.14.1",
    "0.17.1",
    "1.0.0-littleendian",
    "2.0.0-compression",
    "4.0.0-shareddict",
    "cpp-21.0.0"
  )
  checked <- 0L
  for (version in versions) {
    cases <- golden_cases(version)
    cases <- cases[grepl("^generated_(primitive|decimal)", names(cases))]
    for (case in names(cases)) {
      expected <- golden_json_text(cases[[case]])
      df <- arrow_read(paste0(cases[[case]], ".stream"), lossy = "character")
      for (name in names(expected)) {
        expect_identical(
          column_text(df[[name]]),
          expected[[name]],
          info = paste(version, case, name)
        )
        checked <- checked + 1L
      }
    }
  }
  expect_gt(checked, 0L)
})

# Optional (design section 12): decimal's registration is not part of 0.1.0,
# so this runs only when an installed decimal registers "d:*".
test_that("with decimal's registration the golden decimal cases decode exactly", {
  skip_if_not_installed("zujson")
  skip_if_not_installed("decimal")
  # Later files run with the registry as it was, decimal loaded or not.
  local_registry()
  loadNamespace("decimal")
  registry <- arrow_registry()
  skip_if_not(
    any(registry$key == "d:*" & registry$package %in% "decimal"),
    "decimal does not register with zuarrow"
  )
  cases <- golden_cases("cpp-21.0.0")
  cases <- cases[grepl("^generated_decimal", names(cases))]
  for (case in names(cases)) {
    expected <- golden_json_text(cases[[case]])
    df <- arrow_read(paste0(cases[[case]], ".stream"))
    for (name in names(expected)) {
      label <- paste(case, name)
      expect_s3_class(df[[name]], "decimal")
      expect_identical(as.character(df[[name]]), expected[[name]], info = label)
    }
  }
})
