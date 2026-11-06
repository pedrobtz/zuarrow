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
      if (!fetch_file(paste0(base, f), dest)) {
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

# Downloads `url` to `dest`, trying `attempts` times with a growing pause.
# One download in several hundred failing transiently made CI red (#151).
# A failed attempt can leave a partial file, so each one writes to a
# temporary name and only a complete download is renamed into place.
fetch_file <- function(
  url,
  dest,
  attempts = 4L,
  download = utils::download.file,
  pause = Sys.sleep
) {
  part <- paste0(dest, ".part")
  on.exit(unlink(part))
  for (attempt in seq_len(attempts)) {
    ok <- tryCatch(
      download(url, part, mode = "wb", quiet = TRUE) == 0,
      error = function(e) FALSE,
      warning = function(w) FALSE
    )
    if (ok && file.rename(part, dest)) {
      return(TRUE)
    }
    if (attempt < attempts) {
      pause(2^(attempt - 1))
    }
  }
  FALSE
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

# The exact text of each integer and decimal column of a golden case's JSON
# twin (generated_*.json.gz), as a named list of character vectors with NA
# for null slots. The JSON writes a decimal's unscaled integer, so its text
# is scaled here; other columns are left out.
golden_json_text <- function(case_path) {
  con <- gzfile(paste0(case_path, ".json.gz"), "rb")
  bytes <- readBin(con, "raw", 1e8)
  close(con)
  json <- zujson::json_parse_raw(bytes)
  out <- list()
  for (i in seq_along(json$schema$fields)) {
    field <- json$schema$fields[[i]]
    type <- field$type
    if (!type$name %in% c("int", "decimal")) {
      next
    }
    text <- unlist(lapply(json$batches, function(batch) {
      column <- batch$columns[[i]]
      values <- json_number_text(column$DATA)
      valid <- as.logical(unlist(column$VALIDITY))
      if (length(valid) == length(values)) {
        values[!valid] <- NA
      }
      values
    }))
    if (type$name == "decimal") {
      text <- scale_text(text, type$scale)
    }
    out[[field$name]] <- if (is.null(text)) character() else text
  }
  out
}

# JSON integers past 2^53 are strings; the others are numbers.
json_number_text <- function(x) {
  x <- unlist(x)
  if (is.null(x)) {
    return(character())
  }
  if (is.character(x)) x else format(x, scientific = FALSE, trim = TRUE)
}

# "-992" at scale 2 is "-9.92"; at scale 0 it is "-992".
scale_text <- function(text, scale) {
  if (scale <= 0) {
    out <- paste0(text, strrep("0", -scale))
    out[is.na(text)] <- NA
    return(out)
  }
  vapply(
    text,
    function(t) {
      if (is.na(t)) {
        return(NA_character_)
      }
      sign <- if (startsWith(t, "-")) "-" else ""
      digits <- sub("^-", "", t)
      digits <- paste0(strrep("0", max(0, scale + 1 - nchar(digits))), digits)
      n <- nchar(digits)
      paste0(
        sign,
        substr(digits, 1, n - scale),
        ".",
        substr(digits, n - scale + 1, n)
      )
    },
    "",
    USE.NAMES = FALSE
  )
}

# The values of each top-level boolean, floating-point, string, binary,
# date32 and second or millisecond timestamp column of a golden case's JSON
# twin, as a named list of list(kind, type, values). `values` is in the form
# golden_comparable() gives zuarrow's column, with NA (NULL for binary) in
# null slots. Dictionary-encoded columns and other types are left out.
golden_json_values <- function(case_path) {
  con <- gzfile(paste0(case_path, ".json.gz"), "rb")
  bytes <- readBin(con, "raw", 1e8)
  close(con)
  json <- zujson::json_parse_raw(bytes)
  out <- list()
  for (i in seq_along(json$schema$fields)) {
    field <- json$schema$fields[[i]]
    type <- field$type
    kind <- golden_kind(type)
    if (is.null(kind) || !is.null(field$dictionary)) {
      next
    }
    values <- lapply(json$batches, function(batch) {
      column <- batch$columns[[i]]
      valid <- as.logical(unlist(column$VALIDITY))
      data <- golden_json_data(column$DATA, kind, type)
      if (length(valid) == length(data)) {
        data[!valid] <- if (kind == "binary") list(NULL) else NA
      }
      data
    })
    values <- do.call(c, values) %||% golden_json_data(list(), kind, type)
    if (kind == "timestamp") {
      values <- list(values = values, tzone = type$timezone %||% "")
    }
    out[[field$name]] <- list(kind = kind, type = type, values = values)
  }
  out
}

golden_kind <- function(type) {
  switch(
    type$name,
    bool = "logical",
    floatingpoint = if (type$precision != "HALF") "float",
    utf8 = ,
    largeutf8 = "string",
    binary = ,
    largebinary = ,
    fixedsizebinary = "binary",
    date = if (type$unit == "DAY") "date",
    timestamp = if (type$unit %in% c("SECOND", "MILLISECOND")) "timestamp",
    NULL
  )
}

golden_json_data <- function(data, kind, type) {
  data <- unlist(data)
  switch(
    kind,
    logical = as.logical(data) %||% logical(),
    # The JSON prints a float32 in the fewest digits that round trip it, so
    # rounding the parsed double to float32 recovers the stored value.
    float = if (type$precision == "SINGLE") {
      readBin(
        writeBin(as.double(data), raw(), size = 4L),
        "double",
        n = length(data),
        size = 4L
      )
    } else {
      as.double(data) %||% double()
    },
    string = as.character(data) %||% character(),
    binary = lapply(as.character(data), hex_raw),
    date = as.double(data) %||% double(),
    timestamp = as.double(data) %||% double()
  )
}

hex_raw <- function(hex) {
  if (!nzchar(hex)) {
    return(raw())
  }
  starts <- seq(1L, nchar(hex), by = 2L)
  as.raw(strtoi(substring(hex, starts, starts + 1L), 16L))
}

# zuarrow's column in the form golden_json_values() gives the JSON's: a
# timestamp as whole units of its type, and its time zone.
golden_comparable <- function(x, kind, type) {
  switch(
    kind,
    logical = ,
    float = ,
    string = as.vector(x),
    binary = lapply(unclass(x), function(v) {
      if (is.null(v)) NULL else as.vector(v)
    }),
    date = if (inherits(x, "Date")) as.double(unclass(x)),
    timestamp = if (inherits(x, "POSIXct")) {
      scale <- if (type$unit == "MILLISECOND") 1000 else 1
      list(
        values = round(as.double(unclass(x)) * scale),
        tzone = attr(x, "tzone") %||% ""
      )
    }
  )
}

# The text of a column read with lossy = "character": exact text already for
# the columns that needed it, and the printed value for those that convert
# exactly to integer or double.
column_text <- function(x) {
  if (is.character(x)) {
    return(as.vector(x))
  }
  out <- format(as.vector(x), scientific = FALSE, trim = TRUE)
  out[is.na(x)] <- NA
  as.character(out)
}
