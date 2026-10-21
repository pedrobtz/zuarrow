# The committed IPC files of tools/make-test-data.R.
test_data <- function(name) test_path("data", name)

basic_df <- function() readRDS(test_data("basic.rds"))

without_metadata <- function(df) {
  attr(df, "arrow_metadata") <- NULL
  df
}
