# Handles: schema, array and stream external pointers in nanoarrow's r.h
# layout (D6), classed c("zuarrow_<kind>", "nanoarrow_<kind>") (D7).

#' Arrow schemas
#'
#' `arrow_schema()` makes a schema handle from a format string, from an R
#' object, or from any schema, array or stream handle. A handle can come
#' from zuarrow, from 'nanoarrow' or from any producer that uses its
#' layout, such as 'arrow', 'duckdb' or an 'ADBC' driver.
#'
#' A single string is read as an Arrow format string, such as `"i"` for
#' `int32` or `"tsu:UTC"` for a microsecond timestamp in UTC. Any other R
#' object gives the schema it would be written with: a data frame gives a
#' `struct` with one field per column. On a handle, `arrow_schema()` never
#' raises on the content: it returns a zuarrow schema handle as it is,
#' copies any other schema, or asks a stream for it.
#'
#' `format()` gives the type notation Arrow's own tools print, such as
#' `int64` or `struct<x: int32>`, and `print()` shows it.
#'
#' @param x A format string, an R object, or a schema, array or stream
#'   handle.
#' @returns A schema handle of class `c("zuarrow_schema",
#'   "nanoarrow_schema")`.
#' @seealso [arrow_metadata()] for schema metadata, [arrow_equal()] to
#'   compare schemas.
#' @export
#' @examples
#' arrow_schema("l")
#' arrow_schema(data.frame(x = 1:3, y = c("a", "b", "c")))
#' format(arrow_schema(as.Date("2026-10-21")))
arrow_schema <- function(x) {
  call <- sys.call()
  if (zar_is_schema(x) && inherits(x, "zuarrow_schema")) {
    zar_check_live(x)
    return(x)
  }
  if (zar_is_handle(x)) {
    return(zar_check(.Call(zar_c_schema_copy, x)))
  }
  if (is.character(x) && length(x) == 1L && is.null(attributes(x))) {
    if (is.na(x) || !nzchar(x)) {
      zar_abort(
        "format",
        "A format string can't be empty or `NA`.",
        call = call
      )
    }
    return(zar_check(.Call(zar_c_schema_from_spec, zar_spec(x))))
  }
  spec <- zar_infer_spec(x, name = "", call = call)
  zar_check(.Call(zar_c_schema_from_spec, spec))
}

zar_is_schema <- function(x) inherits(x, "nanoarrow_schema")
zar_is_array <- function(x) inherits(x, "nanoarrow_array")
zar_is_stream <- function(x) inherits(x, "nanoarrow_array_stream")
zar_is_handle <- function(x) {
  zar_is_schema(x) || zar_is_array(x) || zar_is_stream(x)
}

# Every batch left in a stream, read to its end.
zar_stream_batches <- function(stream, call) {
  batches <- list()
  repeat {
    batch <- zar_check(.Call(zar_c_stream_next, stream), call = call)
    if (is.null(batch)) {
      return(batches)
    }
    batches[[length(batches) + 1L]] <- batch
  }
}

# The R names of a spec's fields: a field without a name gets "".
zar_field_names <- function(fields) {
  vapply(fields, function(f) if (is.na(f$name)) "" else f$name, "")
}

zar_check_live <- function(x, call = sys.call(-1)) {
  status <- .Call(zar_c_handle_status, x)
  if (status != "live") {
    zar_abort(
      "handle",
      sprintf(
        "The handle is %s.",
        if (status == "null") "a NULL pointer" else status
      ),
      call = call
    )
  }
  invisible(x)
}

zar_spec <- function(
  format,
  name = "",
  flags = 2L,
  metadata = NULL,
  children = list(),
  dictionary = NULL
) {
  list(
    format = format,
    name = name,
    flags = flags,
    metadata = metadata,
    children = children,
    dictionary = dictionary
  )
}

#' @export
format.zuarrow_schema <- function(x, ...) {
  if (.Call(zar_c_handle_status, x) != "live") {
    return("<zuarrow_schema [released]>")
  }
  zar_check(.Call(zar_c_schema_format, x, TRUE))
}

#' @export
print.zuarrow_schema <- function(x, ...) {
  cat("<zuarrow_schema> ", format(x), "\n", sep = "")
  if (.Call(zar_c_handle_status, x) == "live") {
    metadata <- arrow_metadata(x)
    if (length(metadata) > 0L) {
      cat("metadata:\n")
      values <- vapply(
        metadata,
        function(v) {
          if (is.raw(v)) sprintf("<%d raw bytes>", length(v)) else v
        },
        ""
      )
      cat(paste0("  ", names(metadata), ": ", values), sep = "\n")
    }
  }
  invisible(x)
}

#' @export
format.zuarrow_array <- function(x, ...) {
  if (.Call(zar_c_handle_status, x) != "live") {
    return("<zuarrow_array [released]>")
  }
  info <- zar_check(.Call(zar_c_array_info, x))
  type <- zar_check(.Call(zar_c_schema_format, arrow_schema(x), TRUE))
  sprintf(
    "<zuarrow_array %s[%s]>",
    type,
    format(info$length, scientific = FALSE)
  )
}

#' @export
print.zuarrow_array <- function(x, ...) {
  cat(format(x), "\n", sep = "")
  invisible(x)
}

#' @export
format.zuarrow_array_stream <- function(x, ...) {
  if (.Call(zar_c_handle_status, x) != "live") {
    return("<zuarrow_array_stream [released]>")
  }
  sprintf("<zuarrow_array_stream %s>", format(arrow_schema(x)))
}

#' @export
print.zuarrow_array_stream <- function(x, ...) {
  cat(format(x), "\n", sep = "")
  invisible(x)
}
