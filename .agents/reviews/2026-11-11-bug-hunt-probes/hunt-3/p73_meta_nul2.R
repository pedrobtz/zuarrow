source("lib.R")
find <- function(hay, needle) { n <- length(needle); any(vapply(seq_len(length(hay) - n + 1), function(i) identical(hay[i:(i + n - 1)], needle), NA)) }
v <- as.raw(c(0xff, 0x00, 0x61, 0x62))
# a foreign schema with NUL in a metadata value, written through zuarrow
ns <- nanoarrow::na_struct(list(x = nanoarrow::na_int32())); ns$metadata <- list(key = v)
arr <- nanoarrow::as_nanoarrow_array(data.frame(x = 1L), schema = ns)
cat("foreign array schema metadata: "); dput(nanoarrow::infer_nanoarrow_schema(arr)$metadata)
b <- zuarrow::arrow_write(arr, NULL, format = "stream")
cat("bytes in IPC written by zuarrow:", find(b, v), "\n")
cat("arrow reads IPC written by zuarrow: "); print(charToRaw(arrow::read_ipc_stream(b, as_data_frame = FALSE)$schema$metadata$key))
# what does arrow itself write for the same schema?
tab <- arrow::as_arrow_table(arr); b2 <- arrow::write_to_raw(tab, format = "stream")
cat("bytes in IPC written by arrow:", find(b2, v), "\n")
cat("zuarrow reads arrow's IPC: "); dput(zuarrow::arrow_metadata(zuarrow::arrow_read(b2, lazy = TRUE)))
cat("nanoarrow reads arrow's IPC: "); dput(nanoarrow::read_nanoarrow(b2)$get_schema()$metadata)
