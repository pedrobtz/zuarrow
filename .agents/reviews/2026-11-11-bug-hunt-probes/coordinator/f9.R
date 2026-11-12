.libPaths(c(Sys.getenv("W_LIB"), .libPaths())); suppressMessages({library(zuarrow); library(arrow)})
i64 <- function(x) arrow::Array$create(x, type = arrow::string())$cast(arrow::int64())
for (case in list(list("ns", "-9223372036854775808"), list("s", "9223372036854775807"), list("ns", "-1000000001"))) {
  txt <- zuarrow::arrow_to_r(nanoarrow::as_nanoarrow_array(i64(case[[2]])$cast(timestamp(case[[1]], "UTC"))), lossy = "character")
  r <- tryCatch({b <- zuarrow::arrow_array(txt); identical(zuarrow::arrow_to_r(b, lossy = "character"), txt)}, error = function(e) paste(class(e)[1], conditionMessage(e)))
  cat(case[[1]], case[[2]], "->", txt, "->", r, "\n")
}
