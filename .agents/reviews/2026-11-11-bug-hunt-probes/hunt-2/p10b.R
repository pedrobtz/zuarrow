source("common.R")
nest <- function(k) { t <- arrow::int32(); for (i in seq_len(k)) t <- arrow::list_of(t); t }
bytes <- a_stream(list(arrow::record_batch(x = arrow::concat_arrays(type = nest(48)))))
cat("48-level schema, header meta =", msgs(bytes)[[1]]$meta, "bytes\n")
t0 <- proc.time()[[3]]; z <- try_z(arrow_read(bytes, limits = arrow_limits(max_message = 2000)))
cat("max_message=2000 (below header):", if (is_err(z)) z$cls else "OK", sprintf("[%.2fs]\n", proc.time()[[3]] - t0))
cat("-> reached the depth-limit test\n")
t0 <- proc.time()[[3]]; z <- try_z(arrow_read(bytes, limits = arrow_limits(max_depth = 8)))
cat("max_depth=8:", if (is_err(z)) z$cls else "OK", sprintf("[%.2fs]\n", proc.time()[[3]] - t0))
