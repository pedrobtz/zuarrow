# The call of the zuarrow condition `expr` raises, or NULL when it raises
# none (test-calls.R).
caught_call <- function(expr) {
  tryCatch(
    {
      expr
      NULL
    },
    zuarrow_error = function(e) conditionCall(e)
  )
}
