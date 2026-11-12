# registered `from` column: take a batch with get_next, drop the stream, gc, read
library(zuarrow); library(nanoarrow)
arrow_register("l", from = function(x) arrow_array(as.double(unclass(x)), schema = "l"), class = "myint")
n <- 200000
df <- data.frame(a = seq_len(n)); df$b <- structure(as.double(seq_len(n)) * 10, class = "myint")
mode <- commandArgs(TRUE)[1]
s <- arrow_stream(df, batch = n)
rm(df)
if (mode == "nanoarrow") {
  b <- s$get_next()                      # nanoarrow's method on the shared class
} else if (mode == "internal") {
  b <- .Call(zuarrow:::zar_c_stream_next, s)
} else if (mode == "arrow") {
  rdr <- arrow::as_record_batch_reader(nanoarrow::as_nanoarrow_array_stream(s))
  b <- rdr$read_table()
  rdr$.unsafe_delete(); rm(rdr)
}
rm(s); invisible(gc()); invisible(gc())
junk <- lapply(1:200, function(i) numeric(200000))
if (mode == "arrow") {
  v <- as.vector(b$b)[1:3]
} else {
  v <- zuarrow::arrow_to_r(b, lossy = "allow")$b[1:3]
}
print(v)
stopifnot(all(v == c(10, 20, 30)))
cat("OK\n")
