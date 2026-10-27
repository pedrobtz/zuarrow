#' Schema metadata
#'
#' `arrow_metadata()` reads the custom metadata of a schema, or of the
#' schema of an array or stream, as a named character vector. Values that
#' are not valid UTF-8 or that contain a NUL byte are kept as raw vectors,
#' and the result is then a named list.
#'
#' The replacement form returns a copy of the schema with new metadata:
#' `NULL` removes it.
#'
#' @param x A schema, array or stream handle. The replacement form takes a
#'   schema handle.
#' @param value A named character vector, a named list of strings and raw
#'   vectors, or `NULL`.
#' @returns A named character vector, or a named list when a value is
#'   binary. An empty named character vector when there is no metadata.
#' @export
#' @examples
#' schema <- arrow_schema("i")
#' arrow_metadata(schema) <- c(origin = "zuarrow")
#' arrow_metadata(schema)
arrow_metadata <- function(x) {
  call <- sys.call()
  if (!zar_is_handle(x)) {
    zar_abort(
      "handle",
      "`x` must be a schema, array or stream handle.",
      call = call
    )
  }
  raw <- zar_check(.Call(zar_c_schema_metadata, arrow_schema(x)))
  zar_metadata_values(raw)
}

zar_metadata_values <- function(raw) {
  text <- vapply(
    raw,
    function(v) {
      !any(v == as.raw(0L)) && validUTF8(rawToChar(v))
    },
    NA
  )
  if (all(text)) {
    out <- vapply(
      raw,
      function(v) {
        s <- rawToChar(v)
        Encoding(s) <- "UTF-8"
        s
      },
      ""
    )
    names(out) <- names(raw)
    return(out)
  }
  out <- raw
  for (i in which(text)) {
    s <- rawToChar(raw[[i]])
    Encoding(s) <- "UTF-8"
    out[[i]] <- s
  }
  out
}

#' @rdname arrow_metadata
#' @export
`arrow_metadata<-` <- function(x, value) {
  call <- sys.call()
  if (!zar_is_schema(x)) {
    zar_abort(
      "handle",
      "Metadata can only be replaced on a schema handle.",
      call = call
    )
  }
  raw <- zar_metadata_raw(value, call = call)
  zar_check(.Call(zar_c_schema_with_metadata, x, raw))
}

zar_metadata_raw <- function(value, call = sys.call(-1)) {
  if (is.null(value) || length(value) == 0L) {
    return(NULL)
  }
  keys <- names(value)
  ok_chr <- is.character(value) && !anyNA(value)
  ok_list <- is.list(value) &&
    all(vapply(
      value,
      function(v) {
        is.raw(v) || (is.character(v) && length(v) == 1L && !is.na(v))
      },
      NA
    ))
  ok_values <- ok_chr || ok_list
  if (!ok_values || is.null(keys) || anyNA(keys) || any(!nzchar(keys))) {
    zar_abort(
      "type",
      paste(
        "Metadata must be a named character vector",
        "or a named list of strings and raw vectors."
      ),
      call = call
    )
  }
  out <- lapply(as.list(value), function(v) {
    if (is.raw(v)) v else charToRaw(enc2utf8(v))
  })
  names(out) <- enc2utf8(keys)
  out
}
