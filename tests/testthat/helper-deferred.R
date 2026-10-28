# NULL for a vector that is not deferred, otherwise list(made, holds_arrays):
# how many of its strings exist and whether it still keeps the Arrow batches.
deferred_info <- function(x) .Call(zuarrow:::zar_c_deferred_info, x)

# Reaches the deferred vector's methods that no R function calls directly:
# "dataptr" reads every element through STRING_PTR_RO(), "or_null" says
# whether the Dataptr_or_null method has a pointer, "set" sets element `i`
# (1-based) in place, "no_na" calls the No_NA method.
deferred_probe <- function(x, op, i = 0L, value = NA_character_) {
  code <- match(op, c("dataptr", "or_null", "set", "no_na"))
  .Call(zuarrow:::zar_c_deferred_probe, x, code, as.integer(i), value)
}
