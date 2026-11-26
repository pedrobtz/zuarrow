# The built-in type table, the matrix marker, and what reads a type
# exactly.

#' The built-in type table
#'
#' Lists every Arrow type zuarrow converts without a registration: its
#' format string, its R form, whether that form is exact, the R form
#' `lossy = "allow"` gives otherwise, the package that reads it exactly,
#' and the R values [arrow_array()] writes as it.
#'
#' @returns A data frame of character columns: `arrow`, `format`, `r`,
#'   `exact`, `lossy_r`, `exact_with` and `from_r`. `exact` describes when
#'   the R form is exact, as text such as `"yes"`, `"no"` or
#'   `"within +/-2^53"`, not as a logical. `from_r` lists the R values
#'   written as the type: "(schema)" marks those written as it only when
#'   `schema` names it, and in a row of several types `schema` picks any
#'   but the one each value infers. "text" is the character vector with an
#'   `arrow_type` attribute that [arrow_to_r()] gives under
#'   `lossy = "character"`, written as the type that attribute names.
#'   `from_r` is empty for a type zuarrow reads but does not write.
#' @export
#' @examples
#' arrow_types()
arrow_types <- function() {
  text <- "text"
  rows <- list(
    c("null", "n", "logical (NA)", "yes", "", "", "NULL; logical (schema)"),
    c("bool", "b", "logical", "yes", "", "", "logical"),
    c(
      "int8, int16, uint8, uint16",
      "c, s, C, S",
      "integer",
      "yes",
      "",
      "",
      "integer, double, integer64 (schema); text"
    ),
    c(
      "int32",
      "i",
      "integer",
      "unless a value is INT_MIN",
      "integer (NA)",
      "",
      "integer; double, integer64 (schema); text"
    ),
    c(
      "uint32",
      "I",
      "double",
      "yes",
      "",
      "",
      "integer, double, integer64 (schema); text"
    ),
    c(
      "half_float, float, double",
      "e, f, g",
      "double",
      "yes",
      "",
      "",
      "double; integer, double (schema)"
    ),
    c(
      "int64",
      "l",
      "double",
      "within +/-2^53",
      "double, or integer64 with bit64",
      "zuint",
      "integer64; integer, double (schema); text"
    ),
    c(
      "uint64",
      "L",
      "double",
      "up to 2^53",
      "double",
      "zuint",
      "integer, double, integer64 (schema); text"
    ),
    c(
      "utf8, large_utf8, utf8_view",
      "u, U, vu",
      "character",
      "unless a value holds NUL",
      "character, cut at NUL",
      "",
      "character; factor (schema)"
    ),
    c(
      "binary, large_binary, binary_view",
      "z, Z, vz",
      "list of raw",
      "yes",
      "",
      "",
      "list of raw"
    ),
    c(
      "fixed_size_binary",
      "w:n",
      "list of raw, arrow_width",
      "yes",
      "",
      "",
      "list of raw, arrow_width"
    ),
    c("date32", "tdD", "Date", "yes", "", "", "Date; text"),
    c("date64", "tdm", "", "no", "POSIXct", "zutempo", "Date (schema); text"),
    c(
      "timestamp[s]",
      "tss:",
      "POSIXct",
      "within +/-2^53 seconds",
      "POSIXct",
      "zutempo",
      "POSIXct; text"
    ),
    c(
      "timestamp[ms], timestamp[us]",
      "tsm:, tsu:",
      "POSIXct",
      "when the double of seconds rounds back",
      "POSIXct",
      "zutempo",
      "POSIXct; text"
    ),
    c(
      "timestamp[ns]",
      "tsn:",
      "",
      "no",
      "POSIXct",
      "zutempo",
      "POSIXct (schema); text"
    ),
    c(
      "time32, time64",
      "tts, ttm, ttu, ttn",
      "",
      "no",
      "difftime",
      "zutempo",
      text
    ),
    c(
      "duration",
      "tDs, tDm, tDu, tDn",
      "",
      "no",
      "difftime",
      "zutempo",
      "difftime; text"
    ),
    c(
      "decimal32, decimal64, decimal128, decimal256",
      "d:p,s",
      "",
      "no",
      "double",
      "decimal",
      text
    ),
    c("interval", "tiM, tiD, tin", "", "no", "none", "zutempo", text),
    c("dense_union, sparse_union", "+ud:, +us:", "", "no", "none", "", ""),
    c("struct", "+s", "data.frame", "yes", "", "", "data.frame"),
    c(
      "list, large_list, list_view, large_list_view",
      "+l, +L, +vl, +vL",
      "list column",
      "yes",
      "",
      "",
      "list (not the views)"
    ),
    c(
      "fixed_size_list",
      "+w:n",
      "list column; matrix with arrow_matrix()",
      "yes",
      "",
      "",
      "list (schema); matrix with arrow_matrix()"
    ),
    c(
      "map",
      "+m",
      "list column of key/value data frames",
      "yes",
      "",
      "",
      "list of key/value data frames, arrow_keys_sorted"
    ),
    c(
      "dictionary of strings",
      "index + utf8",
      "factor",
      "yes",
      "",
      "",
      "factor"
    ),
    c(
      "dictionary of other values",
      "index + values",
      "the values' R form",
      "as the values",
      "",
      "",
      ""
    ),
    c(
      "run_end_encoded",
      "+r",
      "the values' R form",
      "as the values",
      "",
      "",
      ""
    ),
    c(
      "arrow.bool8 extension",
      "c + ARROW:extension:name",
      "logical",
      "yes",
      "",
      "",
      "logical, arrow_extension"
    )
  )
  out <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)
  names(out) <- c(
    "arrow",
    "format",
    "r",
    "exact",
    "lossy_r",
    "exact_with",
    "from_r"
  )
  out
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

zar_is_struct <- function(schema, call) {
  spec <- zar_check(.Call(zar_c_schema_to_spec, schema), call = call)
  identical(spec$format, "+s")
}
