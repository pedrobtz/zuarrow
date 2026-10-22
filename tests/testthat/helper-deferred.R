# NULL for a vector that is not deferred, otherwise list(made, holds_arrays):
# how many of its strings exist and whether it still keeps the Arrow batches.
deferred_info <- function(x) .Call(zuarrow:::zar_c_deferred_info, x)
