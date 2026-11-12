source("lib.R")
find <- function(hay, needle) { n <- length(needle); which(vapply(seq_len(length(hay) - n + 1), function(i) identical(hay[i:(i + n - 1)], needle), NA)) }
v <- as.raw(c(0xff, 0x00, 0x61, 0x62))
b <- zuarrow::arrow_write(data.frame(x = 1L), NULL, metadata = list(key = v))
cat("value bytes present in the IPC bytes:", length(find(b, v)) > 0, "\n")
s <- zuarrow::arrow_read(b, lazy = TRUE)
cat("zuarrow reads back: "); dput(zuarrow::arrow_metadata(s))
sch <- zuarrow::arrow_schema("i"); zuarrow::arrow_metadata(sch) <- list(key = v)
cat("in memory (no IPC): "); dput(zuarrow::arrow_metadata(sch))
cat("nanoarrow sees: "); dput(nanoarrow::as_nanoarrow_schema(sch)$metadata)
# the same on field metadata through IPC
d <- data.frame(x = 1L); attr(d$x, "arrow_extension") <- "e"; attr(d$x, "arrow_extension_metadata") <- v
r <- tryCatch(zuarrow::arrow_read(zuarrow::arrow_write(d, NULL)), error = function(e) conditionMessage(e)); cat("extension metadata round trip: "); dput(attributes(r$x))
cat("nanoarrow reads IPC metadata: "); dput(nanoarrow::read_nanoarrow(zuarrow::arrow_write(data.frame(x = 1L), NULL, format = "stream", metadata = list(key = v)))$get_schema()$metadata)
