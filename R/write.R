# Writing the Arrow IPC formats (design section 6.8).

#' Write the Arrow IPC formats
#'
#' `arrow_write()` writes a data frame, a `struct` array or a stream as an
#' Arrow IPC file (`format = "file"`, with a footer) or stream (`format =
#' "stream"`). A path ending in `.arrows` defaults to the stream format; any
#' other path, and `x = NULL`, to the file format.
#'
#' A data frame is split into record batches of at most `batch` rows. Each
#' factor is written as a dictionary with one dictionary batch before the
#' first record batch, or as plain strings with `dictionary = FALSE`.
#' Columns with `arrow_extension`, `arrow_extension_metadata` or
#' `arrow_field_metadata` attributes keep them as field metadata, and
#' `metadata` becomes the schema's custom metadata.
#'
#' Bodies are padded to 8 bytes with zeros and are uncompressed by default,
#' so every reader opens the file. `compression = "lz4"` writes LZ4 frames
#' and `"zstd"` zstd frames through 'zukomp', at `level` on the codec's own
#' scale; a buffer that does not shrink is written as it is. The same
#' input and options give the same bytes on every platform.
#'
#' @param data A data frame, a struct array handle or a stream handle.
#' @param x `NULL` to return the bytes, a path, or a connection.
#' @param format `"file"` or `"stream"`.
#' @param compression `"none"`, `"lz4"` or `"zstd"`.
#' @param level `NULL` for the codec's default, or a level on its scale.
#' @param batch The most rows in one record batch, for a data frame.
#' @param dictionary Whether factors are written as dictionaries.
#' @param metadata `NULL`, or a named character vector of schema metadata.
#' @returns A raw vector when `x` is `NULL`, otherwise `x`, invisibly.
#' @seealso [arrow_read()].
#' @export
#' @examples
#' df <- data.frame(x = 1:3, f = factor(c("a", "b", "a")))
#' bytes <- arrow_write(df, NULL)
#' arrow_read(bytes)
#'
#' path <- tempfile(fileext = ".arrows")
#' arrow_write(df, path, compression = "zstd")
#' arrow_read(path)
arrow_write <- function(
  data,
  x = NULL,
  format = c("file", "stream"),
  compression = c("none", "lz4", "zstd"),
  level = NULL,
  batch = 65536L,
  dictionary = TRUE,
  metadata = NULL
) {
  call <- sys.call()
  format <- if (missing(format)) {
    if (is.character(x) && length(x) == 1L && grepl("\\.arrows$", x)) {
      "stream"
    } else {
      "file"
    }
  } else {
    match.arg(format)
  }
  compression <- match.arg(compression)
  if (
    !is.null(level) &&
      (!is.numeric(level) ||
        length(level) != 1L ||
        is.na(level) ||
        level != floor(level))
  ) {
    zar_abort(
      "type",
      "`level` must be `NULL` or one whole number.",
      call = call
    )
  }
  if (
    !is.logical(dictionary) || length(dictionary) != 1L || is.na(dictionary)
  ) {
    zar_abort("type", "`dictionary` must be `TRUE` or `FALSE`.", call = call)
  }
  if (
    !is.null(x) &&
      !inherits(x, "connection") &&
      !(is.character(x) && length(x) == 1L && !is.na(x))
  ) {
    zar_abort(
      "type",
      "`x` must be `NULL`, a path or a connection.",
      call = call
    )
  }

  source <- zar_write_source(data, batch, dictionary, metadata, call)
  bytes <- zar_check(
    .Call(
      zar_c_write,
      source$arrays,
      source$schema,
      list(
        format == "file",
        match(compression, c("none", "lz4", "zstd")) - 1L,
        if (is.null(level)) NA_integer_ else as.integer(level)
      )
    ),
    call = call
  )
  if (is.null(x)) {
    return(bytes)
  }
  if (inherits(x, "connection")) {
    opened <- !isOpen(x)
    if (opened) {
      open(x, "wb")
      on.exit(close(x), add = TRUE)
    }
    writeBin(bytes, x)
    return(invisible(x))
  }
  con <- tryCatch(file(x, "wb"), error = function(e) e, warning = function(w) w)
  if (inherits(con, "condition")) {
    zar_abort(
      "io",
      sprintf("Cannot open `%s` for writing.", x),
      call = call,
      path = x
    )
  }
  on.exit(close(con), add = TRUE)
  writeBin(bytes, con)
  invisible(x)
}

# The schema and batches to write: a data frame batched with its factors
# as dictionaries or strings, an array as one batch, a stream read through.
zar_write_source <- function(data, batch, dictionary, metadata, call) {
  if (is.data.frame(data)) {
    spec <- .Call(zar_c_schema_to_spec, arrow_schema(data))
    if (!dictionary) {
      spec <- zar_without_dictionaries(spec)
    }
    if (!is.null(metadata)) {
      spec$metadata <- zar_metadata_raw(metadata, call = call)
    }
    schema <- zar_check(.Call(zar_c_schema_from_spec, spec), call = call)
    stream <- arrow_stream(data, batch = batch, schema = schema)
  } else if (zar_is_array(data)) {
    stream <- .Call(zar_c_stream_from_arrays, arrow_schema(data), list(data))
  } else if (zar_is_stream(data)) {
    stream <- data
  } else {
    zar_abort(
      "type",
      "`data` must be a data frame, an array or a stream.",
      call = call
    )
  }
  schema <- arrow_schema(stream)
  if (!zar_is_struct(schema)) {
    zar_abort(
      "type",
      "Only a struct array or stream can be written.",
      call = call
    )
  }
  if (!is.data.frame(data) && !is.null(metadata)) {
    arrow_metadata(schema) <- metadata
  }
  arrays <- list()
  repeat {
    next_batch <- zar_check(.Call(zar_c_stream_next, stream), call = call)
    if (is.null(next_batch)) {
      break
    }
    arrays[[length(arrays) + 1L]] <- next_batch
  }
  list(schema = schema, arrays = arrays)
}

zar_without_dictionaries <- function(spec) {
  if (!is.null(spec$dictionary)) {
    spec <- spec$dictionary[c(
      "format",
      "name",
      "flags",
      "metadata",
      "children",
      "dictionary"
    )]
    spec$name <- spec$name
  }
  spec$children <- lapply(spec$children, function(child) {
    name <- child$name
    flags <- child$flags
    metadata <- child$metadata
    out <- zar_without_dictionaries(child)
    out$name <- name
    out$flags <- bitwAnd(flags, bitwNot(1L))
    out$metadata <- metadata
    out
  })
  spec
}
