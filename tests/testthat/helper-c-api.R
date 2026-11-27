# The public C API (inst/include/zuarrow.h) reached from R through the test
# entry points of src/zar_api_r.c, with the options a C caller would build.

# zuarrow_open_stream() on `path`: list(code, kind, message, stream,
# schema_code, next_code, next_message). `limits` NULL with nothing else
# set passes NULL options; `codecs` is "zukomp", "none", "bad-abi" or
# "short".
api_open <- function(
  path,
  columns = NULL,
  indices = NULL,
  limits = arrow_limits(),
  codecs = "zukomp",
  struct_size = NA_integer_
) {
  if (!is.null(limits)) {
    limits <- as.double(unlist(limits[names(formals(arrow_limits))]))
  }
  if (!is.null(indices)) {
    indices <- as.double(indices)
  }
  .Call(
    zuarrow:::zar_c_api_open,
    path,
    columns,
    indices,
    limits,
    codecs,
    as.integer(struct_size)
  )
}

# The class arrow_read() raises for a kind zuarrow_error_kind() names.
api_class <- function(kind) {
  if (identical(kind, "memory")) {
    "zuarrow_error"
  } else {
    paste0("zuarrow_", kind, "_error")
  }
}

# What reading `path` gives: the data frame, or the class of the error.
# Through arrow_read(), or through the C API's stream and arrow_to_r(); for
# the C API a failure after opening also checks zuarrow_error_kind() names
# the class arrow_to_r() raised.
read_outcome <- function(path, ...) {
  tryCatch(arrow_read(path, ...), zuarrow_error = function(e) class(e)[[1]])
}

api_outcome <- function(path, ...) {
  opened <- api_open(path, ...)
  if (opened$code != 0L) {
    return(api_class(opened$kind))
  }
  tryCatch(
    arrow_to_r(opened$stream),
    zuarrow_error = function(e) {
      kind <- .Call(zuarrow:::zar_c_api_kind, opened$stream)
      # A conversion error (a lossy value) leaves the stream unfailed.
      if (!is.null(kind) && !identical(api_class(kind), class(e)[[1]])) {
        return(paste("zuarrow_error_kind() says", kind, "for", class(e)[[1]]))
      }
      class(e)[[1]]
    }
  )
}

api_parse <- function(what, x, digits = 0L, utc = FALSE) {
  .Call(zuarrow:::zar_c_api_parse, what, x, as.integer(digits), utc)
}

# Every IPC input the suite has: the committed data/ files and, when
# fetched, the arrow-testing golden files and crash corpus.
api_files <- function() {
  files <- list.files(test_path("data"), "\\.arrows?$", full.names = TRUE)
  dir <- tryCatch(fixtures_dir(), skip = function(e) NULL)
  if (!is.null(dir)) {
    files <- c(
      files,
      list.files(dir, recursive = TRUE, full.names = TRUE)
    )
  }
  files[!dir.exists(files)]
}
