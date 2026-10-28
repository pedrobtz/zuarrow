# Conversion from R vectors to Arrow arrays (design sections 6.2, 6.4).
# The kernels are in src/zar_from_r.c; R picks the schema and flattens
# list columns, so C never calls R.

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
#' a list of raw vectors to `binary`, a list with the `arrow_keys_sorted`
#' attribute that [arrow_to_r()] gives a map to `map`, any other list to
#' `list<T>` with `T` from its elements, and a data frame to a `struct`. A
#' class registered with [arrow_register()] goes through its `from`
#' handler, and a matrix is written as a `fixed_size_list` with
#' `schema = arrow_matrix()`. The
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
  call <- sys.call()
  handler <- zar_handler_for_class(x)
  if (is.null(schema) && !is.null(handler)) {
    return(zar_from_handler(handler, x, call))
  }
  schema <- zar_schema_for(x, schema, call)
  prepared <- zar_prepare(x, schema, call)
  n <- zar_nrow(x)
  zar_check(.Call(zar_c_from_r, zar_batch(prepared, 0, n, call), schema, 0, n))
}

#' @rdname arrow_array
#' @export
arrow_stream <- function(x, batch = 65536L, schema = NULL) {
  call <- sys.call()
  if (
    !is.numeric(batch) ||
      length(batch) != 1L ||
      is.na(batch) ||
      batch < 1 ||
      batch != floor(batch)
  ) {
    zar_abort("type", "`batch` must be a positive whole number.", call = call)
  }
  schema <- zar_schema_for(x, schema, call)
  prepared <- zar_prepare(x, schema, call)
  n <- zar_nrow(x)
  starts <- if (n == 0) numeric() else seq(0, n - 1, by = batch)
  arrays <- lapply(starts, function(start) {
    len <- min(batch, n - start)
    zar_check(.Call(
      zar_c_from_r,
      zar_batch(prepared, start, len, call),
      schema,
      start,
      len
    ))
  })
  zar_check(.Call(zar_c_stream_from_arrays, schema, arrays))
}

zar_schema_for <- function(x, schema, call = sys.call(-1)) {
  if (inherits(schema, "zuarrow_matrix")) {
    if (!is.matrix(x)) {
      zar_abort(
        "type",
        "`x` must be a matrix for `schema = arrow_matrix()`.",
        call = call
      )
    }
    item <- zar_infer_spec(as.vector(x[0L, , drop = TRUE]), "item", call)
    spec <- zar_spec(paste0("+w:", ncol(x)), "", children = list(item))
    return(zar_check(.Call(zar_c_schema_from_spec, spec), call = call))
  }
  if (is.null(schema)) {
    return(zar_check(
      .Call(zar_c_schema_from_spec, zar_infer_spec(x, name = "", call = call)),
      call = call
    ))
  }
  arrow_schema(schema)
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
zar_prepare <- function(x, schema, call = NULL) {
  zar_prepare_spec(x, zar_check(.Call(zar_c_schema_to_spec, schema)), call)
}

zar_prepare_spec <- function(x, spec, call = NULL) {
  if (!is.null(zar_handler_for_class(x))) {
    return(structure(list(x = x), class = "zar_registered"))
  }
  if (
    is.data.frame(x) &&
      identical(spec$format, "+s") &&
      length(spec$children) == length(x)
  ) {
    out <- lapply(seq_along(x), function(k) {
      zar_prepare_spec(x[[k]], spec$children[[k]], call)
    })
    attributes(out) <- attributes(x)
    return(out)
  }
  variable_list <- spec$format %in% c("+l", "+L", "+m")
  is_list_type <- variable_list || startsWith(spec$format, "+w:")
  if (is_list_type && is.matrix(x)) {
    width <- ncol(x)
    return(structure(
      list(
        offsets = as.double(seq(0, nrow(x)) * width),
        null = rep(FALSE, nrow(x)),
        values = zar_prepare_spec(as.vector(t(x)), spec$children[[1L]], call)
      ),
      class = "zar_list_prep"
    ))
  }
  if (is_list_type && is.list(x) && !is.data.frame(x)) {
    nulls <- zar_null_elements(x)
    if (startsWith(spec$format, "+w:") && any(nulls)) {
      width <- as.integer(substring(spec$format, 4))
      x <- zar_fill_null_lists(x, nulls, width, spec$children[[1L]])
    }
    values <- zar_flatten(x, call)
    child <- spec$children[[1L]]
    if (is.null(values)) {
      values <- zar_empty_like(child)
    }
    return(structure(
      list(
        offsets = c(0, cumsum(zar_element_lengths(x))),
        null = nulls,
        values = zar_prepare_spec(values, child, call)
      ),
      class = "zar_list_prep"
    ))
  }
  x
}

# A fixed_size_list keeps `width` child slots under a null row: the null
# elements become `width` NAs of the other elements' type.
zar_fill_null_lists <- function(x, nulls, width, child) {
  template <- if (all(nulls)) {
    zar_empty_like(child) %||% NA
  } else {
    x[[which(!nulls)[1L]]]
  }
  na_rows <- rep(NA_integer_, width)
  filler <- if (is.data.frame(template)) {
    template[na_rows, , drop = FALSE]
  } else {
    template[na_rows]
  }
  x[nulls] <- list(filler)
  x
}

# An empty R vector of the type a spec describes, for a list column with
# no values at all.
zar_empty_like <- function(spec) {
  if (identical(spec$format, "+s")) {
    columns <- lapply(spec$children, function(child) {
      zar_empty_like(child) %||% logical()
    })
    names(columns) <- paste0("V", seq_along(columns))
    return(structure(columns, class = "data.frame", row.names = integer()))
  }
  if (spec$format %in% c("+l", "+L", "+m") || startsWith(spec$format, "+w:")) {
    return(list())
  }
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
zar_batch <- function(x, start, n, call = NULL) {
  if (inherits(x, "zar_registered")) {
    handler <- zar_handler_for_class(x$x)
    return(zar_from_handler(handler, x$x[seq_len(n) + start], call))
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
        x[[k]] <- zar_batch(x[[k]], start, n, call)
      }
      attributes(x) <- attrs
    }
  }
  x
}
