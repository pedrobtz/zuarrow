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
