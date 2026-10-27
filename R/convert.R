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
#' `utf8` (`large_utf8` past 2^31 - 1 bytes), `factor` to
#' `dictionary<int32, utf8>`, `Date` to `date32`, `POSIXct` to
#' `timestamp[us]` in its time zone or UTC, `difftime` to `duration[us]`,
#' a list of raw vectors to `binary`, any other list to `list<T>` with `T`
#' from its elements, and a data frame to a `struct`. A class registered
#' with [arrow_register()] goes through its `from` handler, and a matrix is
#' written as a `fixed_size_list` with `schema = arrow_matrix()`. The
#' attributes `arrow_extension`, `arrow_extension_metadata` and
#' `arrow_field_metadata` become field metadata. Any other class is a
#' `zuarrow_type_error`.
#'
#' With a `schema`, the values are written as that type and checked: an
#' integer that does not fit `int8`, or a double that is not a whole
#' number for `int64`, is a `zuarrow_lossy_error` naming the row. `POSIXct`
#' and `difftime` values are rounded to the schema's unit.
#'
#' A character vector with an `arrow_type` attribute, as `arrow_to_r()`
#' returns under `lossy = "character"`, is written back as that type: each
#' value is parsed, and text that is not the type's form, or holds more
#' precision than the type, is an error. So the exact text round-trips.
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
  handler <- zar_handler_for_class(x)
  if (is.null(schema) && !is.null(handler)) {
    return(zar_from_handler(handler, x))
  }
  schema <- zar_schema_for(x, schema)
  prepared <- zar_prepare(x, schema)
  zar_check(.Call(
    zar_c_from_r,
    zar_batch(prepared, 0, zar_nrow(x)),
    schema,
    0,
    zar_nrow(x)
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
  prepared <- zar_prepare(x, schema)
  n <- zar_nrow(x)
  starts <- if (n == 0) numeric() else seq(0, n - 1, by = batch)
  arrays <- lapply(starts, function(start) {
    len <- min(batch, n - start)
    zar_check(.Call(
      zar_c_from_r,
      zar_batch(prepared, start, len),
      schema,
      start,
      len
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
  if (is.data.frame(x)) {
    .row_names_info(x, 2L)
  } else if (is.matrix(x)) {
    nrow(x)
  } else {
    length(x)
  }
}

# Prepares an R object for the C builder against its schema: list columns
# and matrices become a zar_list_prep, flattened once (C never calls R),
# and data frames are prepared column by column (section 6.4).
zar_prepare <- function(x, schema) {
  zar_prepare_spec(x, .Call(zar_c_schema_to_spec, schema))
}

zar_prepare_spec <- function(x, spec) {
  if (!is.null(zar_handler_for_class(x))) {
    return(structure(list(x = x), class = "zar_registered"))
  }
  if (
    is.data.frame(x) &&
      identical(spec$format, "+s") &&
      length(spec$children) == length(x)
  ) {
    out <- Map(zar_prepare_spec, x, spec$children)
    attributes(out) <- attributes(x)
    return(out)
  }
  is_list_type <- spec$format %in%
    c("+l", "+L") ||
    startsWith(spec$format, "+w:")
  if (is_list_type && is.matrix(x)) {
    width <- ncol(x)
    return(structure(
      list(
        offsets = as.double(seq(0, nrow(x)) * width),
        null = rep(FALSE, nrow(x)),
        values = zar_prepare_spec(as.vector(t(x)), spec$children[[1L]])
      ),
      class = "zar_list_prep"
    ))
  }
  if (is_list_type && is.list(x) && !is.data.frame(x)) {
    values <- zar_flatten(x)
    child <- spec$children[[1L]]
    if (is.null(values)) {
      values <- zar_empty_like(child)
    }
    return(structure(
      list(
        offsets = c(0, cumsum(zar_element_lengths(x))),
        null = zar_null_elements(x),
        values = zar_prepare_spec(values, child)
      ),
      class = "zar_list_prep"
    ))
  }
  x
}

# An empty R vector of the type a spec describes, for a list column with
# no values at all.
zar_empty_like <- function(spec) {
  switch(
    spec$format,
    n = NULL,
    b = logical(),
    i = integer(),
    g = double(),
    u = character(),
    NULL
  )
}

# Rows [start, start + n) of the registered columns, built by their
# handlers. Every other column is sliced by the C builder.
zar_batch <- function(x, start, n) {
  if (inherits(x, "zar_registered")) {
    handler <- zar_handler_for_class(x$x)
    return(zar_from_handler(handler, x$x[seq_len(n) + start]))
  }
  if (is.data.frame(x)) {
    registered <- vapply(
      x,
      function(col) inherits(col, "zar_registered") || is.data.frame(col),
      NA
    )
    if (any(registered)) {
      # Columns are replaced in the underlying list: a data frame cannot
      # hold an array handle as a column through `[<-`.
      attrs <- attributes(x)
      x <- unclass(x)
      for (k in which(registered)) {
        x[[k]] <- zar_batch(x[[k]], start, n)
      }
      attributes(x) <- attrs
    }
  }
  x
}

#' Matrices as fixed-size lists
#'
#' `arrow_matrix()` asks for a matrix where a `fixed_size_list` is
#' involved, in either direction. As the `schema` of [arrow_array()] it
#' writes a matrix as a `fixed_size_list` with one list per row. As a
#' prototype in the `to` of [arrow_to_r()] it reads a `fixed_size_list`
#' column as a matrix with one row per list, `NA` rows for null lists.
#' Without it, a `fixed_size_list` reads as a list column.
#'
#' @returns A marker object of class `zuarrow_matrix`.
#' @export
#' @examples
#' m <- matrix(1:6, nrow = 2)
#' array <- arrow_array(m, schema = arrow_matrix())
#' array
#' arrow_to_r(array, to = arrow_matrix())
arrow_matrix <- function() {
  structure(list(), class = "zuarrow_matrix")
}

zar_schema_for <- function(x, schema, call = sys.call(-1)) {
  if (inherits(schema, "zuarrow_matrix")) {
    if (!is.matrix(x)) {
      zar_abort(
        "type",
        "`schema = arrow_matrix()` needs a matrix.",
        call = call
      )
    }
    item <- zar_infer_spec(as.vector(x[0L, , drop = TRUE]), "item")
    spec <- zar_spec(paste0("+w:", ncol(x)), "", children = list(item))
    return(zar_check(.Call(zar_c_schema_from_spec, spec), call = call))
  }
  if (is.null(schema)) {
    return(zar_check(
      .Call(zar_c_schema_from_spec, zar_infer_spec(x, name = "")),
      call = call
    ))
  }
  arrow_schema(schema)
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
#' `to` names the R type a column must become: `character()`, `double()`,
#' `integer()`, or [arrow_matrix()] for a `fixed_size_list`. A target that
#' cannot take the column is a `zuarrow_type_error`, never a silent
#' fallback.
#'
#' Nested types follow the table too. A `struct` becomes a data frame
#' column; `list`, `large_list` and the list views become list columns,
#' `NULL` for a null list; a `map` becomes a list of data frames with
#' columns `key` and `value`. A dictionary of strings becomes a factor,
#' ordered when the dictionary is, with the union of every batch's levels;
#' a dictionary of other values, and a run-end encoded array, decode to
#' their values' R form. An extension type converts as its storage and
#' keeps its name and metadata in the `arrow_extension` and
#' `arrow_extension_metadata` attributes, so writing the column back
#' restores it. Field metadata becomes the `arrow_field_metadata`
#' attribute. A type registered with [arrow_register()] goes through its
#' handler.
#'
#' @param x An array or stream handle.
#' @param to `NULL`, or a named list of prototypes, one per column. For an
#'   array that is not a `struct`, a single prototype.
#' @param lossy What to do with a column R cannot hold exactly.
#' @param copy `TRUE` to create every R value during the conversion.
#'   `FALSE` to defer string columns: each becomes a character vector that
#'   keeps the Arrow buffers and creates an element's R string the first
#'   time it is used. Most of the cost of a string column is creating its
#'   R strings, so a result that is only partly read, or passed on, is much
#'   cheaper. The values are checked during the conversion either way, so
#'   `copy = FALSE` raises the same errors at the same time. The vector
#'   holds the batch's memory until every element has been used, and it is
#'   saved by [saveRDS()] as an ordinary character vector. Columns of other
#'   types, and strings read through a dictionary, a run-end encoding or a
#'   `struct` with nulls, are copied either way.
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
arrow_to_r <- function(
  x,
  to = NULL,
  lossy = zar_lossy_policies,
  copy = TRUE
) {
  lossy <- match.arg(lossy)
  call <- sys.call()
  zar_check_flag(copy, "copy", call)
  if (zar_is_array(x)) {
    zar_check_live(x, call = call)
    return(zar_convert(list(x), arrow_schema(x), to, lossy, call, copy = copy))
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
    return(zar_convert(batches, schema, to, lossy, call, copy = copy))
  }
  zar_abort("handle", "`x` must be an array or stream handle.", call = call)
}

#' @rdname arrow_to_r
#' @param stream A stream handle.
#' @returns `arrow_next()` returns the next batch as a data frame (or a
#'   vector, for a stream that is not of `struct`), or `NULL` once the
#'   stream has ended.
#' @export
arrow_next <- function(
  stream,
  to = NULL,
  lossy = zar_lossy_policies,
  copy = TRUE
) {
  lossy <- match.arg(lossy)
  call <- sys.call()
  zar_check_flag(copy, "copy", call)
  if (!zar_is_stream(stream)) {
    zar_abort("handle", "`stream` must be a stream handle.", call = call)
  }
  batch <- zar_check(.Call(zar_c_stream_next, stream), call = call)
  if (is.null(batch)) {
    return(NULL)
  }
  zar_convert(list(batch), arrow_schema(stream), to, lossy, call, copy = copy)
}

zar_bit64_loaded <- function() isNamespaceLoaded("bit64")

# Called from C when a deferred character vector's Arrow array was
# released before all its elements were used (src/zar_altrep.c).
zar_deferred_released <- function() {
  zar_abort(
    "handle",
    "The Arrow array behind this character vector was released before its strings were created.",
    call = NULL
  )
}

zar_check_flag <- function(x, name, call) {
  if (!is.logical(x) || length(x) != 1L || is.na(x)) {
    zar_abort(
      "type",
      sprintf("`%s` must be `TRUE` or `FALSE`.", name),
      call = call
    )
  }
}

zar_is_struct <- function(schema) {
  identical(.Call(zar_c_schema_to_spec, schema)$format, "+s")
}

zar_to_code <- function(proto, call) {
  if (is.null(proto)) {
    return(0L)
  }
  if (inherits(proto, "zuarrow_matrix")) {
    return(4L)
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
      "`to` holds an unsupported target of class <%s>; use character(), double(), integer() or arrow_matrix().",
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
    if (is.list(to) && !inherits(to, "zuarrow_matrix")) {
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

zar_convert <- function(
  arrays,
  schema,
  to,
  lossy,
  call,
  max_depth = 64L,
  copy = TRUE
) {
  spec <- .Call(zar_c_schema_to_spec, schema)
  frame <- identical(spec$format, "+s")
  fields <- if (frame) spec$children else list(spec)
  names <- vapply(fields, function(f) if (is.na(f$name)) "" else f$name, "")
  codes <- zar_to_codes(to, names, frame, call)
  if (length(codes) == 0L) {
    codes <- integer(length(fields))
  }

  # Registered handlers convert their columns in R (section 6.10); an
  # inexact one only when the policy accepts loss.
  handlers <- lapply(seq_along(fields), function(k) {
    if (codes[[k]] != 0L) {
      return(NULL)
    }
    h <- zar_handler_for(fields[[k]]$format, zar_extension_name(fields[[k]]))
    if (is.null(h) || (!h$exact && lossy %in% c("error", "character"))) {
      NULL
    } else {
      h
    }
  })
  handled <- !vapply(handlers, is.null, NA)
  codes[handled] <- 9L

  opts <- list(
    match(lossy, zar_lossy_policies),
    codes,
    zar_bit64_loaded(),
    frame,
    as.integer(max_depth),
    copy
  )
  out <- .Call(zar_c_to_r, arrays, schema, opts)
  if (inherits(out, "zar_failure")) {
    zar_raise_conversion(out, lossy, call)
  }
  for (k in out$warned) {
    zar_lossy_warn(out$names[[k]], out$columns[[k]], spec, frame, k, call)
  }
  for (k in which(handled)) {
    out$columns[[k]] <- zar_apply_handler(
      handlers[[k]],
      arrays,
      k,
      frame,
      schema,
      out$rows,
      call
    )
    if (!handlers[[k]]$exact && lossy == "warn") {
      zar_lossy_warn(names[[k]], NULL, spec, frame, k, call)
    }
  }
  for (k in seq_along(fields)) {
    out$columns[[k]] <- zar_attach_field_metadata(out$columns[[k]], fields[[k]])
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

zar_apply_handler <- function(handler, arrays, k, frame, schema, rows, call) {
  columns <- if (length(arrays) == 0L) {
    field_schema <- if (frame) zar_field_schema(schema, k) else schema
    list(zar_empty_array(field_schema))
  } else if (frame) {
    lapply(arrays, function(a) {
      zar_check(.Call(zar_c_array_child, a, k - 1L), call = call)
    })
  } else {
    arrays
  }
  active <- zar_registry$active
  zar_registry$active <- c(active, handler$key)
  on.exit(zar_registry$active <- active, add = TRUE)
  pieces <- lapply(columns, function(a) handler$to(a, arrow_schema(a)))
  out <- if (length(pieces) == 1L) pieces[[1L]] else do.call(c, unname(pieces))
  if (NROW(out) != rows) {
    zar_abort(
      "registry",
      sprintf(
        "The `to` handler for `%s` returned %d values for %d rows.",
        handler$key,
        NROW(out),
        as.integer(rows)
      ),
      call = call
    )
  }
  out
}

zar_field_schema <- function(schema, k) {
  spec <- .Call(zar_c_schema_to_spec, schema)$children[[k]]
  zar_check(.Call(zar_c_schema_from_spec, spec))
}

# A zero-length array of a schema, for a handler when there are no batches.
zar_empty_array <- function(schema) {
  empty_spec <- function(spec) {
    list(
      length = 0,
      null_count = 0,
      offset = 0,
      buffers = list(),
      children = lapply(spec$children, empty_spec),
      dictionary = if (is.null(spec$dictionary)) {
        NULL
      } else {
        empty_spec(spec$dictionary)
      }
    )
  }
  spec <- .Call(zar_c_schema_to_spec, schema)
  zar_check(.Call(zar_c_array_from_buffers, schema, empty_spec(spec)))
}

# Field metadata other than the extension keys becomes the column's
# arrow_field_metadata attribute, down through nested data frames.
zar_attach_field_metadata <- function(x, spec) {
  if (is.null(x)) {
    return(x)
  }
  keys <- names(spec$metadata)
  own <- spec$metadata[
    !keys %in% c("ARROW:extension:name", "ARROW:extension:metadata")
  ]
  if (length(own) > 0L) {
    attr(x, "arrow_field_metadata") <- zar_metadata_values(own)
  }
  if (is.data.frame(x) && identical(spec$format, "+s")) {
    for (k in seq_along(x)) {
      x[[k]] <- zar_attach_field_metadata(x[[k]], spec$children[[k]])
    }
  }
  x
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
  lossy = zar_lossy_policies,
  copy = TRUE
) {
  out <- arrow_to_r(x, to = to, lossy = match.arg(lossy), copy = copy)
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
  lossy = zar_lossy_policies,
  copy = TRUE
) {
  out <- arrow_to_r(x, to = to, lossy = match.arg(lossy), copy = copy)
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
    c("struct", "+s", "data.frame", "yes", "", ""),
    c(
      "list, large_list, list_view, large_list_view",
      "+l, +L, +vl, +vL",
      "list column",
      "yes",
      "",
      ""
    ),
    c(
      "fixed_size_list",
      "+w:n",
      "list column; matrix with arrow_matrix()",
      "yes",
      "",
      ""
    ),
    c("map", "+m", "list column of key/value data frames", "yes", "", ""),
    c("dictionary of strings", "index + utf8", "factor", "yes", "", ""),
    c(
      "dictionary of other values",
      "index + values",
      "the values' R form",
      "as the values",
      "",
      ""
    ),
    c("run_end_encoded", "+r", "the values' R form", "as the values", "", ""),
    c(
      "arrow.bool8 extension",
      "c + ARROW:extension:name",
      "logical",
      "yes",
      "",
      ""
    )
  )
  out <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  names(out) <- c("arrow", "format", "r", "exact", "lossy_r", "exact_with")
  out
}
