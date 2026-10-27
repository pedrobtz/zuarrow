#' Validate an array or stream
#'
#' Runs the 'nanoarrow' C library's validation on an array, or on every
#' batch of a stream. `"minimal"` checks buffer sizes, `"default"` also
#' checks offsets and lengths, and `"full"` also reads buffer contents:
#' offsets that only increase and dictionary indices in range, plus a check
#' zuarrow adds that every non-null string is valid UTF-8. `"full"` is what
#' zuarrow applies to every IPC input.
#'
#' The C data interface records no buffer sizes, so no level can tell that
#' a buffer is shorter than its array's length implies.
#'
#' Validating a stream reads it to the end, so the stream is consumed.
#'
#' @param x An array or stream handle.
#' @param level The validation level.
#' @returns `TRUE`, invisibly. An invalid array raises
#'   `zuarrow_format_error`, with the path to the offending child in the
#'   message.
#' @export
#' @examples
#' schema <- arrow_schema(data.frame(x = 1:3))
#' arrow_validate(schema)
arrow_validate <- function(x, level = c("full", "default", "minimal")) {
  call <- sys.call()
  level <- zar_arg_match(level, c("full", "default", "minimal"), "level", call)
  code <- match(level, c("minimal", "default", "full"))
  if (zar_is_schema(x)) {
    zar_check_live(x)
    return(invisible(TRUE))
  }
  if (zar_is_array(x)) {
    return(invisible(zar_check(.Call(zar_c_array_validate, x, code))))
  }
  if (zar_is_stream(x)) {
    return(invisible(zar_check(.Call(zar_c_stream_validate, x, code))))
  }
  zar_abort("handle", "`x` must be a schema, array or stream handle.")
}

#' Compare two schemas, arrays or streams
#'
#' Two schemas are equal when their formats, names, flags and children
#' match, and their metadata too unless `metadata = FALSE`. Two arrays are
#' equal when their schemas are and they hold the same values, compared
#' value by value: a null equals a null whatever bytes lie under it, and
#' offsets do not matter. A dictionary or run-end encoded array compares by
#' the values it decodes to. Two streams are equal when their schemas are and they yield
#' the same number of batches, each pair equal. Comparing streams reads
#' them both to the end.
#'
#' @param x,y Two handles of the same kind.
#' @param metadata Whether schema and field metadata must match too.
#' @returns `TRUE` or `FALSE`. `FALSE` carries a `reason` attribute naming
#'   the first difference.
#' @export
#' @examples
#' arrow_equal(arrow_schema("i"), arrow_schema("i"))
#' arrow_equal(arrow_schema("i"), arrow_schema("l"))
arrow_equal <- function(x, y, metadata = TRUE) {
  if (!is.logical(metadata) || length(metadata) != 1L || is.na(metadata)) {
    zar_abort("type", "`metadata` must be `TRUE` or `FALSE`.")
  }
  if (zar_is_schema(x) && zar_is_schema(y)) {
    return(zar_check(.Call(zar_c_schema_equal, x, y, metadata)))
  }
  if (zar_is_array(x) && zar_is_array(y)) {
    return(zar_check(.Call(zar_c_array_equal, x, y, metadata)))
  }
  if (zar_is_stream(x) && zar_is_stream(y)) {
    return(zar_check(.Call(zar_c_stream_equal, x, y, metadata)))
  }
  zar_abort(
    "handle",
    "`x` and `y` must be two schema, two array or two stream handles."
  )
}
