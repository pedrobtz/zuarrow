# A deferred string inside a struct that is converted field by field (a registered
# handler on a sibling field): the vector holds a *borrowed* child handle.
library(zuarrow); library(nanoarrow)
info <- function(x) .Call(zuarrow:::zar_c_deferred_info, x)
arrow_register("tdD", to = function(array, schema) arrow_to_r(array) + 0)   # any exact registration on a sibling
n <- 50000
df <- data.frame(id = seq_len(n)); df$st <- data.frame(d = as.Date("2020-01-01") + seq_len(n), s = sprintf("row-%06d", seq_len(n)), stringsAsFactors = FALSE)
h <- arrow_array(df)
out <- arrow_to_r(h, copy = FALSE)
cat("nested string is deferred:", !is.null(info(out$st$s)), "\n")
top <- arrow_to_r(arrow_array(data.frame(s = df$st$s)) -> h2, copy = FALSE)$s
nanoarrow::nanoarrow_pointer_release(h2)
cat("top-level, producer released: ", tryCatch(top[5], error = function(e) class(e)[1]), "\n")
x <- out$st$s; first <- x[1]
nanoarrow::nanoarrow_pointer_release(h); invisible(gc()); junk <- lapply(1:100, function(i) raw(1e5))
cat("nested, producer released: ")
cat(tryCatch(x[n], error = function(e) class(e)[1]), "\n")
