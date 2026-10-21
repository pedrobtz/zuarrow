# Every condition inherits from zuarrow_error (design section 8). C never
# raises one: it returns a zar_failure and zar_call() turns it into the
# condition here, so C can free what it owns first.

zar_abort <- function(kind, message, call = NULL, ...) {
  class <- c(
    if (!is.null(kind)) paste0("zuarrow_", kind, "_error"),
    "zuarrow_error",
    "error",
    "condition"
  )
  stop(structure(
    class = class,
    list(message = message, call = call, ...)
  ))
}

# Turns a zar_failure returned by .Call() into its condition; passes any
# other value through. Each caller writes its .Call() literally, so R CMD
# check can see the registered routine.
zar_check <- function(out, call = sys.call(-1)) {
  if (inherits(out, "zar_failure")) {
    zar_abort(out$kind, out$message, call = call)
  }
  out
}
