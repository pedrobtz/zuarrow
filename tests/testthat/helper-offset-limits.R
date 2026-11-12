# Helpers of test-offset-limits.R.

format_of_array <- function(x, ...) format(arrow_schema(arrow_array(x, ...)))
