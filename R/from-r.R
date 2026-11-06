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
  x <- zar_prebuild(x, call)
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
  x <- zar_prebuild(x, call)
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

# Each registered column, at the top or inside a data frame, built once by
# its `from` handler on the whole column (section 6.10). Its schema is that
# array's, so a handler whose type depends on the values gives one type for
# the column. A batch is that array, or a copied slice of it for a
# fixed-width layout; any other layout is built again per batch.
zar_prebuild <- function(x, call = NULL) {
  handler <- zar_handler_for_class(x)
  if (!is.null(handler)) {
    attrs <- attributes(x)
    keep <- grep("^arrow_", names(attrs), value = TRUE)
    out <- list(array = zar_from_handler(handler, x, call), x = x)
    attributes(out) <- c(
      list(names = c("array", "x")),
      attrs[keep],
      list(class = "zar_prebuilt")
    )
    return(out)
  }
  if (is.data.frame(x)) {
    built <- FALSE
    attrs <- attributes(x)
    cols <- unclass(x)
    for (k in seq_along(cols)) {
      col <- zar_prebuild(cols[[k]], call)
      if (!identical(col, cols[[k]])) {
        cols[[k]] <- col
        built <- TRUE
      }
    }
    if (built) {
      attributes(cols) <- attrs
      return(cols)
    }
  }
  x
}

zar_nrow <- function(x) {
  if (inherits(x, "zar_prebuilt")) {
    return(zar_check(.Call(zar_c_array_info, x$array))$length)
  }
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
  if (inherits(x, "zar_prebuilt")) {
    return(structure(list(x = x$x, array = x$array), class = "zar_registered"))
  }
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
    if (!is.null(x$array)) {
      # The whole column is the array itself, lent so the caller's handle
      # survives the batch; a fixed-width slice is a copy at offset 0.
      if (start == 0 && n == length(x$x)) {
        return(zar_check(.Call(zar_c_array_borrow, x$array), call = call))
      }
      slice <- zar_check(
        .Call(zar_c_array_slice, x$array, start, n),
        call = call
      )
      if (!is.null(slice)) {
        return(slice)
      }
    }
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
  if (inherits(x, "zar_prebuilt")) {
    spec <- zar_check(.Call(zar_c_schema_to_spec, arrow_schema(x$array)))
    spec$name <- name
    return(spec)
  }
  handler <- zar_handler_for_class(x)
  if (!is.null(handler)) {
    # The whole column, as zar_prebuild() builds it: a handler may pick the
    # type from the values (#113).
    array <- zar_from_handler(handler, x, call)
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
    for (e in present[-1L]) {
      zar_check_same_frame(first, e, "", call)
    }
    return(do.call(rbind, present))
  }
  # c() of ordered factors whose levels differ is a plain factor with
  # their union, which would invent an order: they must share levels.
  # The shared class already keeps ordered and plain factors apart.
  if (is.ordered(first)) {
    levels <- levels(first)
    for (e in present[-1L]) {
      if (!identical(levels(e), levels)) {
        zar_abort(
          "type",
          paste(
            "The ordered factor elements of a list column must have",
            "the same levels."
          ),
          call = call
        )
      }
    }
  }
  # Plain atomic vectors concatenate in one call; classed ones, such as
  # dates or factors, need their c() method.
  if (is.atomic(first) && is.null(oldClass(first))) {
    return(unlist(present, use.names = FALSE))
  }
  do.call(c, present)
}

# The data frame elements of a list column become one struct type, so they
# must have the same column names in the same order, and each column the
# same class, storage type and attributes; rbind() would coerce or reorder
# instead (section 6.4). A plain factor's levels may differ, as a
# dictionary's may between batches; an ordered factor's may not, because
# their union would invent an order.
zar_check_same_frame <- function(a, b, prefix, call = NULL) {
  if (!identical(names(a), names(b))) {
    zar_abort(
      "type",
      sprintf(
        paste(
          "The data frame elements of a list column must have the same",
          "columns%s: found (%s) and (%s)."
        ),
        if (nzchar(prefix)) sprintf(" in `%s`", prefix) else "",
        paste(names(a), collapse = ", "),
        paste(names(b), collapse = ", ")
      ),
      call = call
    )
  }
  for (i in seq_along(a)) {
    name <- paste0(prefix, if (nzchar(prefix)) "$", names(a)[[i]])
    x <- a[[i]]
    y <- b[[i]]
    if (is.data.frame(x) && is.data.frame(y)) {
      zar_check_same_frame(x, y, name, call)
      next
    }
    if (!identical(zar_column_shape(x), zar_column_shape(y))) {
      zar_abort(
        "type",
        sprintf(
          paste(
            "Column `%s` of the data frame elements of a list column has",
            "<%s> in one element and <%s> in another."
          ),
          name,
          paste(class(x), collapse = "/"),
          paste(class(y), collapse = "/")
        ),
        call = call
      )
    }
  }
  invisible()
}

# What of a column must agree between elements: its storage type and every
# attribute but those that follow the values (names, a matrix's row count)
# and a plain factor's levels.
zar_column_shape <- function(x) {
  attrs <- attributes(x)
  if (is.null(attrs)) {
    return(list(typeof(x), NULL))
  }
  attrs$names <- NULL
  if (!is.null(attrs$dim)) {
    attrs$dim <- attrs$dim[-1L]
  }
  attrs$dimnames <- NULL
  if (is.factor(x) && !is.ordered(x)) {
    attrs$levels <- NULL
  }
  list(typeof(x), if (length(attrs)) attrs[order(names(attrs))])
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
  # A handler builds a live array of one value per element, at the top level
  # as in a data frame (#123). A released array is a handle error.
  n <- zar_check(.Call(zar_c_array_info, array), call = call)$length
  if (n != length(x)) {
    zar_abort(
      "registry",
      sprintf(
        "The `from` handler for `%s` built %.0f values, not %.0f.",
        handler$key,
        n,
        length(x)
      ),
      call = call
    )
  }
  array
}
