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
#' @param level `NULL` for the codec's default, or a level on its scale. A
#'   level outside the codec's range is a `zuarrow_codec_error`.
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
    zar_arg_match(format, c("file", "stream"), "format", call)
  }
  compression <- zar_arg_match(
    compression,
    c("none", "lz4", "zstd"),
    "compression",
    call
  )
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
  zar_check_level(level, compression, call)
  zar_check_flag(dictionary, "dictionary", call)
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
    if (!isOpen(x)) {
      zar_io(open(x, "wb"), "Can't open the connection", call)
      on.exit(close(x), add = TRUE)
    }
    zar_io(writeBin(bytes, x), "Can't write to the connection", call)
    return(invisible(x))
  }
  what <- sprintf("Can't open `%s` for writing", x)
  con <- zar_io(file(x, "wb"), what, call, path = x)
  on.exit(close(con), add = TRUE)
  what <- sprintf("Can't write to `%s`", x)
  zar_io(writeBin(bytes, con), what, call, path = x)
  invisible(x)
}

# The schema and batches to write: a data frame batched with its factors
# as dictionaries or strings, an array as one batch, a stream read through.
zar_write_source <- function(data, batch, dictionary, metadata, call) {
  if (is.data.frame(data)) {
    spec <- zar_check(.Call(zar_c_schema_to_spec, arrow_schema(data)))
    if (!dictionary) {
      spec <- zar_without_dictionaries(spec)
    }
    if (!is.null(metadata)) {
      spec$metadata <- zar_metadata_raw(metadata, call = call)
    }
    schema <- zar_check(.Call(zar_c_schema_from_spec, spec), call = call)
    stream <- arrow_stream(data, batch = batch, schema = schema)
  } else if (zar_is_array(data)) {
    # A borrowed array, so the stream does not consume the caller's.
    borrowed <- zar_check(.Call(zar_c_array_borrow, data), call = call)
    stream <- zar_check(
      .Call(zar_c_stream_from_arrays, arrow_schema(data), list(borrowed)),
      call = call
    )
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
  list(schema = schema, arrays = zar_stream_batches(stream, call))
}

# A level outside the codec's range, as zukomp reports it, is a codec error
# before anything is encoded.
zar_check_level <- function(level, compression, call) {
  if (is.null(level) || compression == "none") {
    return(invisible())
  }
  id <- if (compression == "lz4") "lz4-frame" else compression
  codecs <- zukomp::komp_codecs()
  row <- codecs[codecs$id == id, ]
  if (nrow(row) == 1L && !is.na(row$level_min)) {
    if (level < row$level_min || level > row$level_max) {
      zar_abort(
        "codec",
        sprintf(
          "`level` must be between %d and %d for %s, not %s.",
          row$level_min,
          row$level_max,
          compression,
          format(level)
        ),
        call = call
      )
    }
  }
  invisible()
}

zar_without_dictionaries <- function(spec) {
  if (!is.null(spec$dictionary)) {
    spec <- spec$dictionary[names(zar_spec(""))]
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
