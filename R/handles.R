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

# The schema an R object is written with (design section 6.2), with its
# field metadata and extension name from the attributes section 6.6 names.
zar_infer_spec <- function(x, name, call = NULL) {
  spec <- zar_infer_type(x, name, call)
  zar_with_field_metadata(spec, x, call)
}

zar_with_field_metadata <- function(spec, x, call = NULL) {
  metadata <- list()
  field <- attr(x, "arrow_field_metadata", exact = TRUE)
  if (!is.null(field)) {
    metadata <- zar_metadata_raw(field, call = call)
  }
  extension <- attr(x, "arrow_extension", exact = TRUE)
  if (!is.null(extension)) {
    if (
      !is.character(extension) || length(extension) != 1L || is.na(extension)
    ) {
      zar_abort(
        "type",
        "The `arrow_extension` attribute must be one string.",
        call = call
      )
    }
    metadata[["ARROW:extension:name"]] <- charToRaw(enc2utf8(extension))
    ext_metadata <- attr(x, "arrow_extension_metadata", exact = TRUE)
    metadata[["ARROW:extension:metadata"]] <- if (is.raw(ext_metadata)) {
      ext_metadata
    } else if (is.null(ext_metadata)) {
      raw()
    } else {
      charToRaw(enc2utf8(ext_metadata))
    }
  }
  if (length(metadata) > 0L) {
    spec$metadata <- metadata
  }
  spec
}

zar_infer_type <- function(x, name, call = NULL) {
  handler <- zar_handler_for_class(x)
  if (!is.null(handler)) {
    array <- zar_from_handler(handler, x[0L], call)
    spec <- zar_check(.Call(zar_c_schema_to_spec, arrow_schema(array)))
    spec$name <- name
    return(spec)
  }
  if (is.data.frame(x)) {
    # Not Map(): mapply() would evaluate `call`, a language object.
    children <- lapply(seq_along(x), function(k) {
      zar_infer_spec(x[[k]], names(x)[[k]], call)
    })
    return(zar_spec("+s", name, children = unname(children)))
  }
  if (is.null(x)) {
    return(zar_spec("n", name))
  }
  if (is.factor(x)) {
    flags <- if (is.ordered(x)) 3L else 2L
    return(zar_spec("i", name, flags = flags, dictionary = zar_spec("u", "")))
  }
  if (inherits(x, "Date")) {
    return(zar_spec("tdD", name))
  }
  if (inherits(x, "POSIXct")) {
    tz <- attr(x, "tzone")
    tz <- if (is.null(tz) || !nzchar(tz[[1L]])) "UTC" else tz[[1L]]
    return(zar_spec(paste0("tsu:", tz), name))
  }
  if (inherits(x, "difftime")) {
    return(zar_spec("tDu", name))
  }
  if (is.character(x) && !is.null(attr(x, "arrow_type"))) {
    # The exact text of section 6.3 is written back as the type it names.
    type <- attr(x, "arrow_type")
    if (!is.character(type) || length(type) != 1L || is.na(type)) {
      zar_abort(
        "type",
        "The `arrow_type` attribute must be one format string.",
        call = call
      )
    }
    return(zar_spec(type, name))
  }
  if (
    is.logical(x) &&
      identical(attr(x, "arrow_extension", exact = TRUE), "arrow.bool8")
  ) {
    return(zar_spec("c", name))
  }
  if (is.matrix(x)) {
    zar_abort(
      "type",
      paste(
        "Can't infer an Arrow type for a matrix.",
        "Use `schema = arrow_matrix()` to write it as a fixed_size_list."
      ),
      call = call
    )
  }
  plain_list <- is.list(x) && identical(class(x), "list")
  if (!is.object(x) || plain_list) {
    format <- switch(
      typeof(x),
      logical = "b",
      integer = "i",
      double = "g",
      character = if (.Call(zar_c_utf8_over, x, zar_utf8_limit())) {
        "U"
      } else {
        "u"
      },
      NULL
    )
    if (!is.null(format)) {
      return(zar_spec(format, name))
    }
    if (is.list(x)) {
      return(zar_infer_list(x, name, call))
    }
  }
  zar_abort(
    "type",
    sprintf(
      "Can't map an R object of class <%s> to an Arrow type.",
      paste(class(x), collapse = "/")
    ),
    call = call
  )
}

# A list of raw vectors is binary; any other list is list<T>, T from the
# elements, which must share one class (section 6.4).
zar_infer_list <- function(x, name, call = NULL) {
  sorted <- attr(x, "arrow_keys_sorted", exact = TRUE)
  if (!is.null(sorted)) {
    return(zar_infer_map(x, name, sorted, call))
  }
  present <- x[!zar_null_elements(x)]
  if (length(present) > 0L && all(vapply(present, is.raw, NA))) {
    return(zar_spec("z", name))
  }
  values <- zar_flatten(x, call)
  child <- if (is.null(values)) {
    zar_spec("n", "item")
  } else {
    zar_infer_spec(values, "item", call)
  }
  total <- sum(zar_element_lengths(present))
  zar_spec(if (total > 2^31 - 1) "+L" else "+l", name, children = list(child))
}

# A list with the arrow_keys_sorted attribute arrow_to_r() gives a map is a
# map again: its elements data frames of columns key and value (section
# 6.4).
zar_infer_map <- function(x, name, sorted, call = NULL) {
  if (!is.logical(sorted) || length(sorted) != 1L || is.na(sorted)) {
    zar_abort(
      "type",
      "The `arrow_keys_sorted` attribute must be one logical.",
      call = call
    )
  }
  present <- x[!zar_null_elements(x)]
  entries <- vapply(
    present,
    function(e) is.data.frame(e) && identical(names(e), c("key", "value")),
    NA
  )
  if (!all(entries)) {
    zar_abort(
      "type",
      paste(
        "Each element of a map column must be a data frame",
        "with columns `key` and `value`."
      ),
      call = call
    )
  }
  values <- zar_flatten(x, call)
  if (is.null(values)) {
    key <- zar_spec("n", "key")
    value <- zar_spec("n", "value")
  } else {
    key <- zar_infer_spec(values$key, "key", call)
    value <- zar_infer_spec(values$value, "value", call)
  }
  key$flags <- 0L
  zar_spec(
    "+m",
    name,
    flags = if (sorted) 6L else 2L,
    children = list(zar_spec(
      "+s",
      "entries",
      flags = 0L,
      children = list(key, value)
    ))
  )
}

# Which elements of a list are NULL, without an R call per element: only
# the elements of length zero can be.
zar_null_elements <- function(x) {
  null <- lengths(x) == 0L
  if (any(null)) {
    null[null] <- vapply(x[null], is.null, NA, USE.NAMES = FALSE)
  }
  null
}

# How many values each element of a list column holds: rows for a data
# frame, whose values zar_flatten() binds by row, the length otherwise.
zar_element_lengths <- function(x) {
  out <- as.double(lengths(x))
  frames <- vapply(x, is.data.frame, NA, USE.NAMES = FALSE)
  if (any(frames)) {
    out[frames] <- vapply(x[frames], nrow, 0L, USE.NAMES = FALSE)
  }
  out
}

# Every element's values, concatenated, or NULL when there are none.
zar_flatten <- function(x, call = NULL) {
  present <- unname(x[!zar_null_elements(x)])
  if (length(present) == 0L) {
    return(NULL)
  }
  if (length(unique(lapply(present, class))) != 1L) {
    zar_abort(
      "type",
      "The elements of a list column must share one class.",
      call = call
    )
  }
  first <- present[[1L]]
  # c() of functions, environments or calls is a list of them again, so
  # inference would recurse until the C stack overflows.
  if (!is.atomic(first) && !is.list(first)) {
    zar_abort(
      "type",
      sprintf(
        "Can't map a list of <%s> elements to an Arrow type.",
        paste(class(first), collapse = "/")
      ),
      call = call
    )
  }
  if (is.data.frame(first)) {
    return(do.call(rbind, present))
  }
  # Plain atomic vectors concatenate in one call; classed ones, such as
  # dates or factors, need their c() method.
  if (is.atomic(first) && is.null(oldClass(first))) {
    return(unlist(present, use.names = FALSE))
  }
  do.call(c, present)
}

zar_from_handler <- function(handler, x, call = NULL) {
  array <- handler$from(x)
  if (!zar_is_array(array)) {
    zar_abort(
      "registry",
      sprintf(
        "The `from` handler for `%s` did not return an array handle.",
        handler$key
      ),
      call = call
    )
  }
  array
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

#' Package information
#'
#' Reports the versions zuarrow is built from: its own, the vendored
#' 'nanoarrow' C library's, and the IPC metadata version it writes.
#'
#' @returns A named list with `zuarrow`, `nanoarrow` and `ipc_metadata`.
#' @export
#' @examples
#' zuarrow_info()
zuarrow_info <- function() {
  list(
    zuarrow = as.character(utils::packageVersion("zuarrow")),
    nanoarrow = .Call(zar_c_nanoarrow_version),
    ipc_metadata = "V5"
  )
}
