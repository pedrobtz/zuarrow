# Reading the Arrow IPC formats (design section 6.7).

#' Limits on IPC input
#'
#' `arrow_limits()` bounds what [arrow_read()] accepts from untrusted
#' input. Each limit is checked before the bytes it covers are used, and
#' going over one is a `zuarrow_limit_error`.
#'
#' @param max_message The most bytes one message header or body may hold,
#'   and the most bytes one compressed buffer may claim when decompressed.
#' @param max_depth The deepest nesting a schema may have.
#' @param max_batch_rows The most rows one record batch may hold.
#' @param max_bytes The most bytes of input in all. For a list of sources,
#'   the most bytes of all of them together.
#' @param max_dictionary The most bytes that delta dictionary batches may
#'   build in all. A delta onto a dictionary that holds values copies the
#'   whole dictionary into a new one, and every copy counts, so many small
#'   deltas cannot build a large amount of memory from a small input. A
#'   dictionary that deltas extend is also held to `max_batch_rows` values
#'   and `max_message` bytes. The default, 2^28 bytes (256 MiB), is far above
#'   what real deltas build and stops a hostile stream early.
#' @returns A list of class `zuarrow_limits`.
#' @export
#' @examples
#' arrow_limits(max_bytes = 2^30)
arrow_limits <- function(
  max_message = 2^31 - 1,
  max_depth = 64L,
  max_batch_rows = 2^31 - 1,
  max_bytes = Inf,
  max_dictionary = 2^28
) {
  call <- sys.call()
  values <- list(
    max_message = max_message,
    max_depth = max_depth,
    max_batch_rows = max_batch_rows,
    max_bytes = max_bytes,
    max_dictionary = max_dictionary
  )
  for (name in names(values)) {
    v <- values[[name]]
    if (!is.numeric(v) || length(v) != 1L || is.na(v) || v < 0) {
      zar_abort(
        "type",
        sprintf("`%s` must be one non-negative number.", name),
        call = call
      )
    }
  }
  values$max_depth <- as.integer(min(values$max_depth, .Machine$integer.max))
  structure(values, class = "zuarrow_limits")
}

#' Read the Arrow IPC formats
#'
#' `arrow_read()` reads an Arrow IPC file, with its footer (`.arrow`, also
#' called Feather version 2), or an IPC stream (`.arrows`). The framing is
#' found from the first bytes, whatever the source is called.
#'
#' The input is checked before it is used: every message is verified,
#' every buffer must lie inside its message, and every limit of
#' [arrow_limits()] binds, so malformed or hostile bytes are a
#' `zuarrow_format_error` or a `zuarrow_limit_error`, never a crash. A file
#' whose footer repeats the schema differently is a `zuarrow_format_error`
#' too. Each batch then passes the full validation of [arrow_validate()]
#' before it is converted. Bodies compressed with LZ4 or zstd are
#' decompressed through 'zukomp'. Big-endian input is a
#' `zuarrow_format_error`.
#'
#' Dictionary batches, and the deltas a stream may send between record
#' batches, are applied as the format says; a file that replaces a
#' dictionary is an error, as the format forbids it. A delta extends a
#' dictionary of fixed-width, binary or string values; a delta onto a
#' dictionary of any other values is a `zuarrow_format_error`.
#'
#' A raw vector is read where it is. With `lazy = TRUE` the handle holds a
#' copy instead, because a handle can be passed to another consumer that
#' outlives the vector.
#'
#' @param x A path, a raw vector, or a connection, which is read to its end.
#'   Or a list of these, each a whole IPC stream, read as one: Spark Connect,
#'   for one, sends each batch of a result as its own stream. Every stream
#'   must have the first one's schema, or it is a `zuarrow_format_error`.
#'   Every source in the list is read into memory when the call starts, and
#'   `max_bytes` binds all of them together.
#' @param columns `NULL` for every column, or the names or positions of the
#'   top-level columns to read. Only those are decoded.
#' @param lazy `FALSE` to read every batch into one data frame; `TRUE` to
#'   return a stream handle whose batches are decoded by [arrow_next()],
#'   one at a time. For a list of sources the handle reads their batches
#'   in order, one stream after another.
#'   With `lazy = TRUE`, `to`, `lossy` and `copy` belong to that later
#'   conversion, and setting one here is a `zuarrow_type_error`.
#' @inheritParams arrow_to_r
#' @param limits An [arrow_limits()] object.
#' @returns A data frame, or with `lazy = TRUE` a stream handle.
#' @seealso [arrow_to_r()] for the conversion and its `lossy` policy.
#' @export
#' @examples
#' path <- tempfile(fileext = ".arrows")
#' df <- data.frame(x = 1:3, y = c("a", "b", "c"))
#' arrow_write(df, path, format = "stream")
#' arrow_read(path)
arrow_read <- function(
  x,
  columns = NULL,
  lazy = FALSE,
  to = NULL,
  lossy = zar_lossy_policies,
  limits = arrow_limits(),
  copy = TRUE
) {
  call <- sys.call()
  lossy <- zar_arg_match(lossy, zar_lossy_policies, "lossy", call)
  if (!inherits(limits, "zuarrow_limits")) {
    zar_abort("type", "`limits` must come from arrow_limits().", call = call)
  }
  zar_check_flag(lazy, "lazy", call)
  zar_check_flag(copy, "copy", call)
  converting <- !is.null(to) || lossy != "error" || !copy
  if (lazy && converting) {
    zar_abort(
      "type",
      paste(
        "`to`, `lossy` and `copy` apply when converting;",
        "with `lazy = TRUE` pass them to arrow_next() or arrow_to_r()."
      ),
      call = call
    )
  }
  if (is.list(x) && !is.object(x)) {
    return(zar_read_list(x, columns, lazy, to, lossy, limits, copy, call))
  }
  stream <- zar_open_reader(x, columns, lazy, limits, call)
  if (lazy) {
    return(stream)
  }
  schema <- arrow_schema(stream)
  batches <- zar_stream_batches(stream, call)
  zar_convert(
    batches,
    schema,
    to,
    lossy,
    call,
    max_depth = limits$max_depth,
    copy = copy
  )
}

# A reader over one source, with only `columns` decoded.
zar_open_reader <- function(x, columns, lazy, limits, call) {
  source <- zar_read_source(x, limits, call)
  bounds <- limits[c(
    "max_message",
    "max_depth",
    "max_batch_rows",
    "max_bytes",
    "max_dictionary"
  )]
  stream <- zar_check(
    .Call(
      zar_c_reader_open,
      source,
      as.double(unlist(bounds)),
      # A raw vector is read in place only when this call consumes the
      # stream; a lazy handle may leave R, so it reads a copy.
      !lazy
    ),
    call = call
  )
  if (!is.null(columns)) {
    zar_check(
      .Call(
        zar_c_reader_select,
        stream,
        zar_column_index(stream, columns, call)
      ),
      call = call
    )
  }
  stream
}

# Several IPC streams read as one, as Spark Connect sends a result: each
# message repeats the schema, which must be the first one's. `max_bytes`
# binds the input of every source together, whatever kind each is.
zar_read_list <- function(x, columns, lazy, to, lossy, limits, copy, call) {
  if (length(x) == 0L) {
    zar_abort("type", "`x` must hold at least one IPC stream.", call = call)
  }
  streams <- vector("list", length(x))
  used <- 0
  for (i in seq_along(x)) {
    # A connection is read up to what the earlier sources left.
    left <- limits
    left$max_bytes <- limits$max_bytes - used
    source <- zar_read_source(x[[i]], left, call)
    used <- used + if (is.raw(source)) length(source) else file.size(source)
    if (used > limits$max_bytes) {
      zar_abort(
        "limit",
        sprintf(
          "The %.0f bytes of input exceed `max_bytes` (%.0f).",
          used,
          limits$max_bytes
        ),
        call = call
      )
    }
    streams[[i]] <- zar_open_reader(source, columns, lazy, limits, call)
  }
  schema <- arrow_schema(streams[[1L]])
  for (i in seq_along(streams)[-1L]) {
    if (!arrow_equal(arrow_schema(streams[[i]]), schema)) {
      zar_abort(
        "format",
        sprintf("Stream %d's schema differs from the first stream's.", i),
        call = call
      )
    }
  }
  if (lazy) {
    # The sources are held in memory, and arrow_next() decodes their
    # batches one at a time, stream after stream.
    return(zar_check(.Call(zar_c_reader_chain, streams), call = call))
  }
  batches <- unlist(
    lapply(streams, zar_stream_batches, call = call),
    recursive = FALSE
  )
  zar_convert(
    batches,
    schema,
    to,
    lossy,
    call,
    max_depth = limits$max_depth,
    copy = copy
  )
}

zar_read_source <- function(x, limits, call) {
  if (is.raw(x)) {
    return(x)
  }
  if (inherits(x, "connection")) {
    return(zar_read_connection(x, limits, call))
  }
  if (is.character(x) && length(x) == 1L && !is.na(x)) {
    if (!file.exists(x) || dir.exists(x)) {
      zar_abort(
        "io",
        sprintf("Can't open `%s`: no such file.", x),
        call = call,
        path = x
      )
    }
    return(x)
  }
  zar_abort(
    "type",
    "`x` must be a path, a raw vector, a connection or a list of them.",
    call = call
  )
}

# A connection is read through R's connection API in blocks, so a gzipped
# file or a socket arrives as it is read, up to max_bytes.
zar_read_connection <- function(con, limits, call) {
  if (!isOpen(con)) {
    zar_io(open(con, "rb"), "Can't open the connection", call)
    on.exit(close(con), add = TRUE)
  }
  blocks <- list()
  total <- 0
  repeat {
    block <- zar_io(
      readBin(con, raw(), 1048576L),
      "Can't read the connection",
      call
    )
    if (length(block) == 0L) {
      break
    }
    total <- total + length(block)
    if (total > limits$max_bytes) {
      zar_abort(
        "limit",
        "The connection holds more than max_bytes.",
        call = call
      )
    }
    blocks[[length(blocks) + 1L]] <- block
  }
  unlist(blocks, use.names = FALSE) %||% raw()
}

zar_column_index <- function(stream, columns, call) {
  spec <- zar_check(.Call(zar_c_schema_to_spec, arrow_schema(stream)))
  names <- zar_field_names(spec$children)
  if (is.character(columns)) {
    idx <- match(columns, names)
    if (anyNA(idx)) {
      zar_abort(
        "type",
        sprintf(
          "No column called %s.",
          paste0("`", columns[is.na(idx)], "`", collapse = ", ")
        ),
        call = call
      )
    }
  } else if (
    is.numeric(columns) &&
      all(is.finite(columns)) &&
      all(columns == floor(columns))
  ) {
    # Checked as doubles, so a position past the integer range is out of
    # range, not an NA with a coercion warning.
    if (any(columns < 1 | columns > length(names))) {
      zar_abort("type", "A column position is out of range.", call = call)
    }
    idx <- as.integer(columns)
  } else {
    zar_abort(
      "type",
      "`columns` must be column names or positions.",
      call = call
    )
  }
  idx - 1L
}
