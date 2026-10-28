# Conversion from Arrow arrays to R vectors (design sections 5, 6.3, 6.9).
# The kernels are in src/zar_to_r.c; R picks the policy and the per-column
# targets, applies registered handlers, and raises the conditions.

zar_lossy_policies <- c("error", "character", "warn", "allow")

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
#' columns `key` and `value`, and an `arrow_keys_sorted` attribute that
#' writes it back as a map. A dictionary of strings becomes a factor,
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
  call <- sys.call()
  lossy <- zar_arg_match(lossy, zar_lossy_policies, "lossy", call)
  zar_check_flag(copy, "copy", call)
  if (zar_is_array(x)) {
    zar_check_live(x, call = call)
    return(zar_convert(list(x), arrow_schema(x), to, lossy, call, copy = copy))
  }
  if (zar_is_stream(x)) {
    schema <- arrow_schema(x)
    batches <- zar_stream_batches(x, call)
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
  call <- sys.call()
  lossy <- zar_arg_match(lossy, zar_lossy_policies, "lossy", call)
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

#' @rdname arrow_to_r
#' @param row.names Must be `NULL`: the rows of a converted data frame have
#'   no names.
#' @param optional Ignored. Column names always come from the schema.
#' @param ... Unused.
#' @returns The `as.data.frame()` methods return a data frame. An array or
#'   stream that is not of `struct` is a `zuarrow_type_error`.
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
  call <- sys.call()
  zar_check_row_names(row.names, call)
  lossy <- zar_arg_match(lossy, zar_lossy_policies, "lossy", call)
  out <- arrow_to_r(x, to = to, lossy = lossy, copy = copy)
  if (!is.data.frame(out)) {
    zar_abort(
      "type",
      "Only a stream of struct converts to a data frame.",
      call = call
    )
  }
  out
}

#' @rdname arrow_to_r
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
  call <- sys.call()
  zar_check_row_names(row.names, call)
  lossy <- zar_arg_match(lossy, zar_lossy_policies, "lossy", call)
  out <- arrow_to_r(x, to = to, lossy = lossy, copy = copy)
  if (!is.data.frame(out)) {
    zar_abort(
      "type",
      "Only a struct array converts to a data frame.",
      call = call
    )
  }
  out
}

#' @rdname arrow_to_r
#' @param mode Must be `"any"`: the array converts to its own R form, as
#'   `arrow_to_r()` gives it, with the default `lossy = "error"`.
#' @export
as.vector.zuarrow_array <- function(x, mode = "any") {
  call <- sys.call()
  if (!identical(mode, "any")) {
    zar_abort(
      "type",
      "`mode` must be \"any\". Use `arrow_to_r()` with `to` for another type.",
      call = call
    )
  }
  arrow_to_r(x)
}

zar_check_row_names <- function(row.names, call) {
  if (!is.null(row.names)) {
    zar_abort("type", "`row.names` must be `NULL`.", call = call)
  }
}

zar_bit64_loaded <- function() isNamespaceLoaded("bit64")

# Called from C when a deferred character vector's Arrow array was
# released before all its elements were used (src/zar_altrep.c).
zar_deferred_released <- function() {
  zar_abort(
    "handle",
    paste(
      "The Arrow array behind this character vector was released",
      "before its strings were created."
    ),
    call = NULL
  )
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
      paste(
        "Each target in `to` must be character(), double(), integer()",
        "or arrow_matrix(), not an object of class <%s>."
      ),
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
  copy = TRUE,
  prefix = ""
) {
  spec <- zar_check(.Call(zar_c_schema_to_spec, schema))
  frame <- identical(spec$format, "+s")
  fields <- if (frame) spec$children else list(spec)
  names <- zar_field_names(fields)
  codes <- zar_to_codes(to, names, frame, call)
  if (length(codes) == 0L) {
    codes <- integer(length(fields))
  }

  # Registered handlers convert their columns in R (section 6.10); an
  # inexact one only when the policy accepts loss. A struct with a handled
  # field at any depth is converted in R too, field by field.
  handlers <- lapply(seq_along(fields), function(k) {
    if (codes[[k]] != 0L) {
      return(NULL)
    }
    zar_field_handler(fields[[k]], lossy)
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
    zar_raise_conversion(out, call, prefix)
  }
  for (k in out$warned) {
    path <- zar_field_path(prefix, out$names[[k]], k)
    zar_lossy_warn(path, spec, frame, k, call)
  }
  nulls <- if (frame && any(handled)) zar_struct_nulls(arrays, call)
  for (k in which(handled)) {
    out$columns[[k]] <- if (isTRUE(handlers[[k]]$nested)) {
      zar_convert_struct_field(
        arrays,
        k,
        schema,
        lossy,
        call,
        max_depth,
        copy,
        prefix = paste0(zar_field_path(prefix, names[[k]], k), "$")
      )
    } else {
      zar_apply_handler(
        handlers[[k]],
        arrays,
        k,
        frame,
        schema,
        out$rows,
        call
      )
    }
    if (!is.null(nulls)) {
      out$columns[[k]] <- zar_null_rows(out$columns[[k]], nulls)
    }
    if (!handlers[[k]]$exact && lossy == "warn") {
      zar_lossy_warn(
        zar_field_path(prefix, names[[k]], k),
        spec,
        frame,
        k,
        call
      )
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

# The handler for a field, or list(nested = TRUE) for a struct one of
# whose fields, at any depth, has a handler; NULL otherwise.
zar_field_handler <- function(field, lossy) {
  h <- zar_handler_for(field$format, zar_extension_name(field))
  if (!is.null(h) && (h$exact || !lossy %in% c("error", "character"))) {
    return(h)
  }
  if (identical(field$format, "+s")) {
    for (child in field$children) {
      if (!is.null(zar_field_handler(child, lossy))) {
        return(list(key = field$format, nested = TRUE, exact = TRUE))
      }
    }
  }
  NULL
}

# A struct field converted as a data frame of its own, so its fields'
# handlers apply.
zar_convert_struct_field <- function(
  arrays,
  k,
  schema,
  lossy,
  call,
  max_depth,
  copy,
  prefix
) {
  children <- lapply(arrays, function(a) {
    zar_check(.Call(zar_c_array_child, a, k - 1L), call = call)
  })
  out <- zar_convert(
    children,
    zar_field_schema(schema, k),
    NULL,
    lossy,
    call,
    max_depth = max_depth - 1L,
    copy = copy,
    prefix = prefix
  )
  attr(out, "arrow_metadata") <- NULL
  out
}

# The null rows of a stream of struct arrays, or NULL when none is null.
zar_struct_nulls <- function(arrays, call) {
  pieces <- lapply(arrays, function(a) {
    zar_check(.Call(zar_c_array_nulls, a), call = call)
  })
  if (all(vapply(pieces, is.null, NA))) {
    return(NULL)
  }
  unlist(Map(
    function(piece, a) {
      piece %||% logical(.Call(zar_c_array_info, a)$length)
    },
    pieces,
    arrays
  ))
}

# A handled column with the rows of a null enclosing struct set to NA, as
# the built-in conversion sets them.
zar_null_rows <- function(x, rows) {
  if (is.data.frame(x)) {
    for (k in seq_along(x)) {
      x[[k]] <- zar_null_rows(x[[k]], rows)
    }
    return(x)
  }
  if (is.matrix(x)) {
    x[rows, ] <- NA
    return(x)
  }
  if (is.list(x) && !is.object(x)) {
    x[rows] <- list(NULL)
    return(x)
  }
  x[rows] <- NA
  x
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
  spec <- zar_check(.Call(zar_c_schema_to_spec, schema))$children[[k]]
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
  spec <- zar_check(.Call(zar_c_schema_to_spec, schema))
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

# A nested field is named by its path from the top-level column, such as
# `s$b`; a field without a name by its position.
zar_field_path <- function(prefix, name, k) {
  if (nzchar(prefix) && !nzchar(name)) {
    return(paste0(prefix, k))
  }
  paste0(prefix, name)
}

zar_column_label <- function(name, column) {
  if (nzchar(name)) {
    sprintf("Column `%s`", name)
  } else {
    sprintf("Column %d", column)
  }
}

zar_raise_conversion <- function(failure, call, prefix = "") {
  column <- failure$column %||% 1L
  name <- zar_field_path(prefix, failure$name %||% "", column)
  label <- zar_column_label(name, column)
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
  # A string with an embedded NUL has no text form, so lossy = "character"
  # cannot help it.
  text <- !isFALSE(failure$text)
  hint <- if (never) {
    "Arrow intervals and unions have no R form."
  } else {
    paste0(
      if (!is.null(target)) {
        sprintf("Load %s to read it exactly, or use", target)
      } else {
        "Use"
      },
      if (text) " `lossy = \"character\"` for its exact text, or",
      " `lossy = \"allow\"` to accept the loss."
    )
  }
  zar_abort(
    "lossy",
    sprintf(
      "%s (Arrow format `%s`) can't be converted to R exactly: %s. %s",
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
