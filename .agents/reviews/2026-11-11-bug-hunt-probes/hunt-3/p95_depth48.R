source("lib.R")
nest <- function(d) { x <- 1L; for (i in seq_len(d)) x <- list(x); x }
d <- as.integer(commandArgs(TRUE)[1]); df <- data.frame(id = 1L); df$l <- list(nest(d - 1))
b <- zuarrow::arrow_write(df, NULL, format = "stream"); writeBin(b, sprintf("depth%d.arrows", d))
cat("written", length(b), "bytes\n")
cat("libarrow:", tryCatch({ t <- arrow::read_ipc_stream(b, as_data_frame = FALSE); t$ValidateFull(); "reads it" }, error = function(e) conditionMessage(e)), "\n")
cat("nanoarrow:", tryCatch({ nanoarrow::read_nanoarrow(b)$get_schema(); "reads schema" }, error = function(e) conditionMessage(e)), "\n")
t0 <- Sys.time(); r <- tryCatch({ zuarrow::arrow_read(b); "reads it" }, error = function(e) paste(class(e)[1], conditionMessage(e)))
cat("zuarrow:", r, " in", round(as.numeric(Sys.time() - t0, units = "secs"), 2), "s\n")
