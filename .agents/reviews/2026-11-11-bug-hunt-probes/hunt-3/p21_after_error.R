# A reader stream after a failed get_next: what do later calls return?
source("lib.R"); source("ipcwalk.R")
t_a <- arrow::record_batch(f = factor(c("a", "b", "a")), n = 1:3)
t_b <- arrow::record_batch(f = factor(c("y", "z", "z")), n = 4:6)   # a replacement dictionary
t_c <- arrow::record_batch(f = factor(c("y", "z", "y")), n = 7:9)
rdr <- arrow::RecordBatchReader$create(batches = list(t_a, t_b, t_c))
bytes <- zuarrow::arrow_write(nanoarrow::as_nanoarrow_array_stream(rdr), NULL, format = "stream")
w <- check_stream(bytes, "replacement stream"); print(w$msgs)
print(zuarrow::arrow_read(bytes))
# Corrupt the second dictionary batch's body: its offsets buffer.
m <- w$msgs; d2 <- m[which(m$type == "dict")[2], ]
bad <- bytes; body_at <- d2$offset + d2$meta
bad[body_at + 5:8] <- as.raw(c(0xff, 0xff, 0xff, 0x7f))   # second offset = INT32_MAX
s <- zuarrow::arrow_read(bad, lazy = TRUE)
for (i in 1:5) {
  r <- try_c(zuarrow::arrow_next(s))
  cat("call", i, ": "); if (is_err(r)) cat("[", r$cls, "]", substr(r$msg, 1, 90), "\n") else if (is.null(r)) cat("NULL (end)\n") else cat(paste(r$f, r$n, collapse = " "), "\n")
}
cat("-- the same through nanoarrow's get_next (a foreign consumer)\n")
s <- zuarrow::arrow_read(bad, lazy = TRUE)
for (i in 1:5) { r <- try_c(s$get_next()); cat("call", i, ": "); if (is_err(r)) cat("error", substr(r$msg, 1, 80), "\n") else if (is.null(r)) cat("NULL\n") else { d <- zuarrow::arrow_to_r(r); cat(paste(d$f, d$n, collapse = " "), "\n") } }
cat("-- corrupt record batch 2 instead (file format)\n")
fb <- zuarrow::arrow_write(data.frame(n = 1:6, s = letters[1:6]), NULL, format = "file", batch = 2)
f <- check_file(fb); b2 <- f$batches[2, ]; bad <- fb
bad[b2$offset + b2$meta + 8 + 5:8] <- as.raw(c(0xff, 0xff, 0xff, 0x7f))
s <- zuarrow::arrow_read(bad, lazy = TRUE)
for (i in 1:5) { r <- try_c(zuarrow::arrow_next(s)); cat("call", i, ": "); if (is_err(r)) cat("[", r$cls, "]", substr(r$msg, 1, 90), "\n") else if (is.null(r)) cat("NULL (end)\n") else cat(paste(r$n, r$s, collapse = " "), "\n") }
