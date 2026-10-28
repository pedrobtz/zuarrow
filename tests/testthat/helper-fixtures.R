# apache/arrow-testing's IPC corpus (design section 9) at a pinned commit.
# The files are not shipped: a developer fetches them with
# tools/fetch-fixtures into tests/testthat/fixtures/, and CI sets
# ZUARROW_FETCH_FIXTURES so the first test that needs them downloads them
# under tempdir(). Without either, the oracle tests skip. With the variable
# set, a download that fails is a test failure, not a skip, so CI cannot go
# green without the oracles.
fixtures_commit <- function() "9ff285c88565f0f6abc855918c6a342e70e4909c"

fixtures_dir <- function() {
  local <- test_path("fixtures")
  if (dir.exists(local)) {
    return(local)
  }
  if (!nzchar(Sys.getenv("ZUARROW_FETCH_FIXTURES"))) {
    testthat::skip(
      "the arrow-testing fixtures are absent; run tools/fetch-fixtures"
    )
  }
  dir <- file.path(tempdir(), "zuarrow-fixtures")
  stamp <- file.path(dir, ".complete")
  if (!file.exists(stamp)) {
    files <- readLines(test_path("fixtures-files.txt"))
    files <- files[!startsWith(files, "#") & nzchar(files)]
    base <- sprintf(
      "https://raw.githubusercontent.com/apache/arrow-testing/%s/data/",
      fixtures_commit()
    )
    for (f in files) {
      dest <- file.path(dir, f)
      dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
      ok <- tryCatch(
        utils::download.file(
          paste0(base, f),
          dest,
          mode = "wb",
          quiet = TRUE
        ) ==
          0,
        error = function(e) FALSE,
        warning = function(w) FALSE
      )
      if (!ok) {
        stop(
          "ZUARROW_FETCH_FIXTURES is set, but ",
          f,
          " could not be fetched.",
          call. = FALSE
        )
      }
    }
    file.create(stamp)
  }
  dir
}

golden_cases <- function(version) {
  dir <- file.path(fixtures_dir(), "arrow-ipc-stream", "integration", version)
  testthat::skip_if_not(dir.exists(dir), paste("no fixtures for", version))
  cases <- sub("\\.stream$", "", list.files(dir, "\\.stream$"))
  stats::setNames(file.path(dir, cases), cases)
}

# Unions and intervals have no R form; golden cases are read as exact text.
no_r_form <- function(case) grepl("union|interval", case)

read_golden <- function(path) {
  tryCatch(arrow_read(path, lossy = "character"), zuarrow_error = function(e) e)
}

# The expected outcome of each crash-corpus file: file (relative to
# fixtures/ or to tests/testthat for data/), expect, note.
crash_expected <- function() {
  utils::read.csv(
    test_path("crash-expected.csv"),
    comment.char = "#",
    stringsAsFactors = FALSE
  )
}

# The outcome of reading a crash file: "data.frame" or the condition's
# first class.
crash_outcome <- function(path) {
  result <- tryCatch(
    arrow_read(path, lossy = "allow"),
    zuarrow_error = function(e) e
  )
  if (is.data.frame(result)) "data.frame" else class(result)[[1]]
}
