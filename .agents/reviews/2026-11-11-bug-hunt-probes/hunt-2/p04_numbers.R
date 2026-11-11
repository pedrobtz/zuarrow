source("common.R")
df <- data.frame(a = c(11L, 12L, 13L, 14L), s = c("w", "xx", "yyy", "zzzz"), stringsAsFactors = FALSE)
bytes <- a_stream(list(arrow::record_batch(df))); m <- msgs(bytes); L <- locate(bytes, m[[2]])
str(L[c("n_nodes", "n_buffers")]); for (k in 0:(L$n_buffers-1)) cat("buf", k, get64(bytes, L$buffers + 16*k), get64(bytes, L$buffers + 16*k + 8), "\n")
both(bytes, "baseline")
for (v in c(3, 5, 0, -1, 2^31, 2^62)) both(put(bytes, L$length, v), paste("batch length", v))
for (v in c(3, 5, 0, -1, 2^40)) both(put(bytes, L$nodes, v), paste("node0 (a) length", v))
for (v in c(3, 5, 0, -1)) both(put(bytes, L$nodes + 16, v), paste("node1 (s) length", v))
for (v in c(3, 5)) { for (cols in list("a", "s", c("s","a"))) both(put(bytes, L$nodes, v), paste("node0 len", v, "columns", paste(cols, collapse=",")), columns = cols) }
for (v in c(3, 5)) { for (cols in list("a", "s")) both(put(bytes, L$nodes + 16, v), paste("node1 len", v, "columns", paste(cols, collapse=",")), columns = cols) }
for (v in c(3, 5)) for (cols in list("a", "s")) both(put(bytes, L$length, v), paste("batch length", v, "columns", cols), columns = cols)
for (v in c(1, 4, 5, -1, 2^62)) both(put(bytes, L$nodes + 8, v), paste("node0 null_count", v, "(no validity)"))
# buffers
for (k in 0:(L$n_buffers - 1)) for (v in c(-8, 4, 8, 1000, 2^62)) both(put(bytes, L$buffers + 16 * k, v), paste("buffer", k, "offset", v))
for (k in 0:(L$n_buffers - 1)) for (v in c(-1, 0, 8, 15, 1000, 2^62)) both(put(bytes, L$buffers + 16 * k + 8, v), paste("buffer", k, "length", v))
# body length
for (d in c(-8, -1, 1, 8, 16, 2^40, -2^40)) both(put(bytes, L$body_length, get64(bytes, L$body_length) + d), paste("bodyLength +", d))
