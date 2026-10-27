# Small helpers shared by the R files.

# One of `choices`, as match.arg() picks it but exactly and raising
# zuarrow_type_error. The whole default vector means its first element.
zar_arg_match <- function(x, choices, name, call) {
  if (identical(x, choices)) {
    return(choices[[1L]])
  }
  if (!is.character(x) || length(x) != 1L || !x %in% choices) {
    zar_abort(
      "type",
      sprintf(
        "`%s` must be one of %s.",
        name,
        paste0("\"", choices, "\"", collapse = ", ")
      ),
      call = call
    )
  }
  x
}

# Runs one I/O step. A warning or error from it becomes zuarrow_io_error,
# whose message keeps the cause after `what`.
zar_io <- function(expr, what, call, ...) {
  out <- tryCatch(expr, error = function(e) e, warning = function(w) w)
  if (inherits(out, "condition")) {
    zar_abort(
      "io",
      sprintf("%s: %s", what, conditionMessage(out)),
      call = call,
      ...
    )
  }
  out
}

`%||%` <- function(x, y) if (is.null(x)) y else x

zar_check_flag <- function(x, name, call) {
  if (!is.logical(x) || length(x) != 1L || is.na(x)) {
    zar_abort(
      "type",
      sprintf("`%s` must be `TRUE` or `FALSE`.", name),
      call = call
    )
  }
}
