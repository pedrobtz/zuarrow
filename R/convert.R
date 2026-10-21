# Conversion between R vectors and Arrow arrays (design sections 5, 6.2,
# 6.3, 6.9). The kernels are C; R picks the schema, the policy and the
# per-column targets, and raises the conditions.

zar_lossy_policies <- c("error", "character", "warn", "allow")

#' Build an Arrow array or stream from R
#'
#' `arrow_array()` converts one R vector, or a data frame, to an array
#' handle. `arrow_stream()` converts a data frame to a stream of record
#' batches of at most `batch` rows each.
#'
#' Without a `schema`, each R class maps to one Arrow type: `logical` to
#' `bool`, `integer` to `int32`, `double` to `double`, `character` to
#' `utf8` (`large_utf8` past 2^31 - 1 bytes), `Date` to `date32`, `POSIXct`
#' to `timestamp[us]` in its time zone or UTC, `difftime` to
#' `duration[us]`, a list of raw vectors to `binary`, and a data frame to a
#' `struct`. Any other class is a `zuarrow_type_error`.
#'
#' With a `schema`, the values are written as that type and checked: an
#' integer that does not fit `int8`, or a double that is not a whole
#' number for `int64`, is a `zuarrow_lossy_error` naming the row. `POSIXct`
#' and `difftime` values are rounded to the schema's unit.
#'
#' Every `NA` becomes a null with a zeroed slot. `NaN` stays a value.
#'
#' @param x An R vector or a data frame.
#' @param schema `NULL`, a format string or a schema handle.
#' @param batch The largest number of rows in one batch.
#' @returns `arrow_array()` returns an array handle; `arrow_stream()` a
#'   stream handle.
#' @seealso [arrow_to_r()] for the way back, [arrow_types()] for the table.
#' @export
#' @examples
#' array <- arrow_array(c(1.5, NA, 3))
#' array
#' arrow_to_r(array)
#'
#' stream <- arrow_stream(data.frame(x = 1:5), batch = 2)
#' as.data.frame(stream)
arrow_array <- function(x, schema = NULL) {
  schema <- zar_schema_for(x, schema)
  zar_check(.Call(
    zar_c_from_r,
    x,
    schema,
    0,
    zar_nrow(x),
    if (is.null(attr(schema, "zar_given"))) zar_utf8_limit() else NA_real_
  ))
}

#' @rdname arrow_array
#' @export
arrow_stream <- function(x, batch = 65536L, schema = NULL) {
  if (
    !is.numeric(batch) ||
      length(batch) != 1L ||
      is.na(batch) ||
      batch < 1 ||
      batch != floor(batch)
  ) {
    zar_abort("type", "`batch` must be a positive whole number.")
  }
  schema <- zar_schema_for(x, schema)
  n <- zar_nrow(x)
  starts <- if (n == 0) numeric() else seq(0, n - 1, by = batch)
  arrays <- lapply(starts, function(start) {
    zar_check(.Call(
      zar_c_from_r,
      x,
      schema,
      start,
      min(batch, n - start),
      NA_real_
    ))
  })
  zar_check(.Call(zar_c_stream_from_arrays, schema, arrays))
}

# The most bytes utf8's 32-bit offsets address. An internal option lowers it
# so the switch to large_utf8 can be tested without 2 GB of strings.
zar_utf8_limit <- function() {
  getOption("zuarrow.utf8_limit", 2^31 - 1)
}

zar_nrow <- function(x) {
  if (is.data.frame(x)) .row_names_info(x, 2L) else length(x)
}

zar_schema_for <- function(x, schema, call = sys.call(-1)) {
  if (is.null(schema)) {
    return(zar_check(
      .Call(zar_c_schema_from_spec, zar_infer_spec(x, name = "")),
      call = call
    ))
  }
  out <- arrow_schema(schema)
  attr(out, "zar_given") <- TRUE
  out
}

#' Convert Arrow data to R
#'
#' `arrow_to_r()` converts an array to an R vector, and a stream or a
#' `struct` array to a data frame with one column per field. The result
#' carries no zuarrow class: it is a plain base R object.
#'
#' A conversion is exact or it fails. `lossy` decides what happens to a
#' column that R cannot hold exactly, such as an `int64` with a value past
#' 2^53, a `decimal128`, or a nanosecond timestamp:
#'
#' * `"error"`, the default, raises `zuarrow_lossy_error`, naming the
#'   column, the Arrow type, the first offending row where there is one,
#'   and the package that would read the column exactly.
#' * `"character"` returns the values' exact text: integers as digits,
#'   decimals with their scale, timestamps in ISO 8601 at the type's
#'   precision. The column carries the Arrow format string in its
#'   `arrow_type` attribute.
#' * `"warn"` converts to the nearest R type and raises one
#'   `zuarrow_lossy_warning` per column.
#' * `"allow"` converts to the nearest R type silently. An `int64` column
#'   becomes `bit64`'s `integer64`, exactly, when `bit64` is loaded.
#'
#' Intervals and unions have no R form and always fail.
#'
#' `to` names the R type a column must become: `character()`, `double()`
#' or `integer()`. A target that cannot take the column is a
#' `zuarrow_type_error`, never a silent fallback.
#'
#' @param x An array or stream handle.
#' @param to `NULL`, or a named list of prototypes, one per column. For an
#'   array that is not a `struct`, a single prototype.
#' @param lossy What to do with a column R cannot hold exactly.
#' @returns An R vector, or a data frame.
#' @seealso [arrow_array()] for the way there, [arrow_types()] for the
#'   table.
#' @export
#' @examples
#' arrow_to_r(arrow_array(1:3))
#'
#' big <- arrow_array(2^53 + 2, schema = "l")
#' try(arrow_to_r(big))
#' arrow_to_r(big, lossy = "character")
arrow_to_r <- function(x, to = NULL, lossy = zar_lossy_policies) {
  lossy <- match.arg(lossy)
  call <- sys.call()
  if (zar_is_array(x)) {
    zar_check_live(x, call = call)
    return(zar_convert(list(x), arrow_schema(x), to, lossy, call))
  }
  if (zar_is_stream(x)) {
    schema <- arrow_schema(x)
    batches <- list()
    repeat {
      batch <- zar_check(.Call(zar_c_stream_next, x), call = call)
      if (is.null(batch)) {
        break
      }
      batches[[length(batches) + 1L]] <- batch
    }
    return(zar_convert(batches, schema, to, lossy, call))
  }
  zar_abort("handle", "`x` must be an array or stream handle.", call = call)
}

#' @rdname arrow_to_r
#' @param stream A stream handle.
#' @returns `arrow_next()` returns the next batch as a data frame (or a
#'   vector, for a stream that is not of `struct`), or `NULL` once the
#'   stream has ended.
#' @export
arrow_next <- function(stream, to = NULL, lossy = zar_lossy_policies) {
  lossy <- match.arg(lossy)
  call <- sys.call()
  if (!zar_is_stream(stream)) {
    zar_abort("handle", "`stream` must be a stream handle.", call = call)
  }
  batch <- zar_check(.Call(zar_c_stream_next, stream), call = call)
  if (is.null(batch)) {
    return(NULL)
  }
  zar_convert(list(batch), arrow_schema(stream), to, lossy, call)
}

zar_bit64_loaded <- function() isNamespaceLoaded("bit64")

zar_is_struct <- function(schema) {
  identical(.Call(zar_c_schema_to_spec, schema)$format, "+s")
}

zar_to_code <- function(proto, call) {
  if (is.null(proto)) {
    return(0L)
  }
  if (!is.object(proto) && length(proto) == 0L) {
    code <- match(typeof(proto), c("character", "double", "integer"))
    if (!is.na(code)) {
      return(code)
    }
  }
  zar_abort(
    "type",
    sprintf(
      "`to` holds an unsupported target of class <%s>; use character(), double() or integer().",
      paste(class(proto), collapse = "/")
    ),
    call = call
  )
}

zar_to_codes <- function(to, names, frame, call) {
  if (is.null(to)) {
    return(integer())
  }
  if (!frame) {
    if (is.list(to)) {
      if (length(to) != 1L) {
        zar_abort(
          "type",
          "`to` must be a single prototype for an array.",
          call = call
        )
      }
      to <- to[[1L]]
    }
    return(zar_to_code(to, call))
  }
  if (!is.list(to) || is.null(names(to)) || any(!nzchar(names(to)))) {
    zar_abort("type", "`to` must be a named list of prototypes.", call = call)
  }
  unknown <- setdiff(names(to), names)
  if (length(unknown) > 0L) {
    zar_abort(
      "type",
      sprintf(
        "`to` names no column called %s.",
        paste0("`", unknown, "`", collapse = ", ")
      ),
      call = call
    )
  }
  codes <- integer(length(names))
  for (name in names(to)) {
    codes[match(name, names)] <- zar_to_code(to[[name]], call)
  }
  codes
}

zar_convert <- function(arrays, schema, to, lossy, call) {
  spec <- .Call(zar_c_schema_to_spec, schema)
  frame <- identical(spec$format, "+s")
  names <- if (frame) vapply(spec$children, `[[`, "", "name") else ""
  names[is.na(names)] <- ""
  opts <- list(
    match(lossy, zar_lossy_policies),
    zar_to_codes(to, names, frame, call),
    zar_bit64_loaded(),
    frame
  )
  out <- .Call(zar_c_to_r, arrays, schema, opts)
  if (inherits(out, "zar_failure")) {
    zar_raise_conversion(out, lossy, call)
  }
  for (k in out$warned) {
    zar_lossy_warn(out$names[[k]], out$columns[[k]], spec, frame, k, call)
  }
  if (!frame) {
    return(out$columns[[1L]])
  }
  df <- out$columns
  names(df) <- out$names
  attr(df, "row.names") <- .set_row_names(as.integer(out$rows))
  class(df) <- "data.frame"
  metadata <- zar_metadata_values(spec$metadata)
  if (length(metadata) > 0L) {
    attr(df, "arrow_metadata") <- metadata
  }
  df
}

# The family package that reads a format exactly (design section 3), or
# NULL when none is planned.
zar_exact_target <- function(format) {
  if (format %in% c("l", "L")) {
    return("zuint")
  }
  if (startsWith(format, "d:")) {
    return("decimal")
  }
  if (grepl("^(ts|tt|tD|ti)", format) || identical(format, "tdm")) {
    return("zutempo")
  }
  NULL
}

zar_column_label <- function(name, column) {
  if (nzchar(name)) {
    sprintf("Column `%s`", name)
  } else {
    sprintf("Column %d", column)
  }
}

zar_raise_conversion <- function(failure, lossy, call) {
  name <- if (is.null(failure$name)) "" else failure$name
  label <- zar_column_label(name, failure$column %||% 1L)
  format <- failure$format %||% ""
  if (!identical(failure$kind, "lossy")) {
    zar_abort(
      failure$kind,
      sprintf("%s (Arrow format `%s`): %s.", label, format, failure$message),
      call = call,
      column = name,
      arrow_type = format
    )
  }
  target <- zar_exact_target(format)
  never <- grepl("^(\\+u|ti)", format)
  hint <- if (never) {
    "Arrow intervals and unions have no R form."
  } else {
    paste0(
      if (!is.null(target)) {
        sprintf("Load %s to read it exactly, or use", target)
      } else {
        "Use"
      },
      " `lossy = \"character\"` for its exact text, or `lossy = \"allow\"` to accept the loss."
    )
  }
  zar_abort(
    "lossy",
    sprintf(
      "%s (Arrow format `%s`) cannot be converted to R exactly: %s. %s",
      label,
      format,
      failure$message,
      hint
    ),
    call = call,
    column = name,
    arrow_type = format,
    row = if (is.na(failure$row)) NULL else failure$row,
    target = target
  )
}

zar_lossy_warn <- function(name, column, spec, frame, k, call) {
  format <- if (frame) spec$children[[k]]$format else spec$format
  warning(structure(
    class = c(
      "zuarrow_lossy_warning",
      "zuarrow_warning",
      "warning",
      "condition"
    ),
    list(
      message = sprintf(
        "%s (Arrow format `%s`) was converted to R with loss.",
        zar_column_label(name, k),
        format
      ),
      call = call,
      column = name,
      arrow_type = format
    )
  ))
}

`%||%` <- function(x, y) if (is.null(x)) y else x

#' @export
as.data.frame.zuarrow_array_stream <- function(
  x,
  row.names = NULL,
  optional = FALSE,
  ...,
  to = NULL,
  lossy = zar_lossy_policies
) {
  out <- arrow_to_r(x, to = to, lossy = match.arg(lossy))
  if (!is.data.frame(out)) {
    zar_abort("type", "Only a stream of struct converts to a data frame.")
  }
  out
}

#' @export
as.data.frame.zuarrow_array <- function(
  x,
  row.names = NULL,
  optional = FALSE,
  ...,
  to = NULL,
  lossy = zar_lossy_policies
) {
  out <- arrow_to_r(x, to = to, lossy = match.arg(lossy))
  if (!is.data.frame(out)) {
    zar_abort("type", "Only a struct array converts to a data frame.")
  }
  out
}

#' @export
as.vector.zuarrow_array <- function(x, mode = "any") {
  arrow_to_r(x)
}

#' The built-in type table
#'
#' Lists every Arrow type zuarrow converts without a registration: its
#' format string, its R form, whether that form is exact, the R form
#' `lossy = "allow"` gives otherwise, and the package that reads it
#' exactly.
#'
#' @returns A data frame with columns `arrow`, `format`, `r`, `exact`,
#'   `lossy_r` and `exact_with`.
#' @export
#' @examples
#' arrow_types()
arrow_types <- function() {
  rows <- list(
    c("null", "n", "logical (NA)", "yes", "", ""),
    c("bool", "b", "logical", "yes", "", ""),
    c("int8, int16, uint8, uint16", "c, s, C, S", "integer", "yes", "", ""),
    c("int32", "i", "integer", "unless a value is INT_MIN", "integer (NA)", ""),
    c("uint32", "I", "double", "yes", "", ""),
    c("half_float, float, double", "e, f, g", "double", "yes", "", ""),
    c(
      "int64",
      "l",
      "double",
      "within +/-2^53",
      "double, or integer64 with bit64",
      "zuint"
    ),
    c("uint64", "L", "double", "up to 2^53", "double", "zuint"),
    c(
      "utf8, large_utf8, utf8_view",
      "u, U, vu",
      "character",
      "unless a value holds NUL",
      "character, cut at NUL",
      ""
    ),
    c(
      "binary, large_binary, binary_view",
      "z, Z, vz",
      "list of raw",
      "yes",
      "",
      ""
    ),
    c("fixed_size_binary", "w:n", "list of raw, arrow_width", "yes", "", ""),
    c("date32", "tdD", "Date", "yes", "", ""),
    c("date64", "tdm", "", "no", "POSIXct", "zutempo"),
    c(
      "timestamp[s], timestamp[ms]",
      "tss:, tsm:",
      "POSIXct",
      "within +/-2^53 units",
      "POSIXct",
      "zutempo"
    ),
    c(
      "timestamp[us], timestamp[ns]",
      "tsu:, tsn:",
      "",
      "no",
      "POSIXct",
      "zutempo"
    ),
    c("time32, time64", "tts, ttm, ttu, ttn", "", "no", "difftime", "zutempo"),
    c("duration", "tDs, tDm, tDu, tDn", "", "no", "difftime", "zutempo"),
    c(
      "decimal32, decimal64, decimal128, decimal256",
      "d:p,s",
      "",
      "no",
      "double",
      "decimal"
    ),
    c("interval", "tiM, tiD, tin", "", "no", "none", "zutempo"),
    c("dense_union, sparse_union", "+ud:, +us:", "", "no", "none", ""),
    c("struct", "+s", "data.frame", "yes", "", "")
  )
  out <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  names(out) <- c("arrow", "format", "r", "exact", "lossy_r", "exact_with")
  out
}
