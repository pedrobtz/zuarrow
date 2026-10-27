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
#' @param max_bytes The most bytes of input in all.
#' @returns A list of class `zuarrow_limits`.
#' @export
#' @examples
#' arrow_limits(max_bytes = 2^30)
arrow_limits <- function(
  max_message = 2^31 - 1,
  max_depth = 64L,
  max_batch_rows = 2^31 - 1,
  max_bytes = Inf
) {
  values <- list(
    max_message = max_message,
    max_depth = max_depth,
    max_batch_rows = max_batch_rows,
    max_bytes = max_bytes
  )
  for (name in names(values)) {
    v <- values[[name]]
    if (!is.numeric(v) || length(v) != 1L || is.na(v) || v < 0) {
      zar_abort("type", sprintf("`%s` must be one non-negative number.", name))
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
#' before it is converted. Bodies compressed with LZ4 or zstd are decompressed through
#' 'zukomp'. Big-endian input is a `zuarrow_format_error`.
#'
#' Dictionary batches, and the deltas a stream may send between record
#' batches, are applied as the format says; a file that replaces a
#' dictionary is an error, as the format forbids it.
#'
#' A raw vector is read where it is. With `lazy = TRUE` the handle holds a
#' copy instead, because a handle can be passed to another consumer that
#' outlives the vector.
#'
#' @param x A path, a raw vector, or a connection, which is read to its end.
#' @param columns `NULL` for every column, or the names or positions of the
#'   top-level columns to read. Only those are decoded.
#' @param lazy `FALSE` to read every batch into one data frame; `TRUE` to
#'   return a stream handle whose batches are decoded by [arrow_next()].
#'   With `lazy = TRUE`, `to`, `lossy` and `copy` belong to that later
#'   conversion, and setting one here is a `zuarrow_type_error`.
#' @inheritParams arrow_to_r
#' @param limits An [arrow_limits()] object.
#' @returns A data frame, or with `lazy = TRUE` a stream handle.
#' @seealso [arrow_to_r()] for the conversion and its `lossy` policy.
#' @export
#' @examples
#' path <- tempfile(fileext = ".arrows")
#' stream <- arrow_stream(data.frame(x = 1:3, y = c("a", "b", "c")))
#' if (requireNamespace("nanoarrow", quietly = TRUE)) {
#'   nanoarrow::write_nanoarrow(stream, path)
#'   arrow_read(path)
#' }
arrow_read <- function(
  x,
  columns = NULL,
  lazy = FALSE,
  to = NULL,
  lossy = zar_lossy_policies,
  limits = arrow_limits(),
  copy = TRUE
) {
  lossy <- match.arg(lossy)
  call <- sys.call()
  if (!inherits(limits, "zuarrow_limits")) {
    zar_abort("type", "`limits` must come from arrow_limits().", call = call)
  }
  if (!is.logical(lazy) || length(lazy) != 1L || is.na(lazy)) {
    zar_abort("type", "`lazy` must be `TRUE` or `FALSE`.", call = call)
  }
  zar_check_flag(copy, "copy", call)
  if (lazy && (!is.null(to) || lossy != "error" || !copy)) {
    zar_abort(
      "type",
      paste(
        "`to`, `lossy` and `copy` apply when converting;",
        "with `lazy = TRUE` pass them to arrow_next() or arrow_to_r()."
      ),
      call = call
    )
  }
  source <- zar_read_source(x, limits, call)
  stream <- zar_check(
    .Call(
      zar_c_reader_open,
      source,
      as.double(unlist(limits[c(
        "max_message",
        "max_depth",
        "max_batch_rows",
        "max_bytes"
      )])),
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
  if (lazy) {
    return(stream)
  }
  schema <- arrow_schema(stream)
  batches <- list()
  repeat {
    batch <- zar_check(.Call(zar_c_stream_next, stream), call = call)
    if (is.null(batch)) {
      break
    }
    batches[[length(batches) + 1L]] <- batch
  }
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
        sprintf("Cannot open `%s`: no such file.", x),
        call = call,
        path = x
      )
    }
    return(x)
  }
  zar_abort(
    "type",
    "`x` must be a path, a raw vector or a connection.",
    call = call
  )
}

# A connection is read through R's connection API in blocks, so a gzipped
# file or a socket arrives as it is read, up to max_bytes.
zar_read_connection <- function(con, limits, call) {
  opened <- !isOpen(con)
  if (opened) {
    ok <- tryCatch(
      {
        open(con, "rb")
        TRUE
      },
      error = function(e) e
    )
    if (!isTRUE(ok)) {
      zar_abort(
        "io",
        sprintf("Cannot open the connection: %s", conditionMessage(ok)),
        call = call
      )
    }
    on.exit(close(con), add = TRUE)
  }
  blocks <- list()
  total <- 0
  repeat {
    block <- tryCatch(readBin(con, raw(), 1048576L), error = function(e) e)
    if (inherits(block, "error")) {
      zar_abort(
        "io",
        sprintf("Cannot read the connection: %s", conditionMessage(block)),
        call = call
      )
    }
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
  names <- vapply(
    spec$children,
    function(f) if (is.na(f$name)) "" else f$name,
    ""
  )
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
    is.numeric(columns) && !anyNA(columns) && all(columns == floor(columns))
  ) {
    idx <- as.integer(columns)
    if (any(idx < 1L | idx > length(names))) {
      zar_abort("type", "A column position is out of range.", call = call)
    }
  } else {
    zar_abort(
      "type",
      "`columns` must be column names or positions.",
      call = call
    )
  }
  idx - 1L
}
