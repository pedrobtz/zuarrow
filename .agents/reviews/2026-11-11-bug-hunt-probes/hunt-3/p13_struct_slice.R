source("lib.R")
st <- arrow::StructArray$create(data.frame(x = 1:5, y = letters[1:5]))$Slice(0, 3)
h <- nanoarrow::as_nanoarrow_array(st)
str(list(len = h$length, child_len = h$children$x$length, offset = h$offset))
for (fmt in c("stream", "file")) {
  bytes <- zuarrow::arrow_write(h, NULL, format = fmt)
  cat(fmt, "\n arrow:    ", conditionMessage(tryCatch(arrow::read_ipc_stream(bytes), error = identity) -> r) %||% "", "\n")
  r1 <- try_c(if (fmt == "stream") arrow::read_ipc_stream(bytes) else arrow::read_ipc_file(bytes)); cat(" arrow:    ", if (is_err(r1)) r1$msg else nrow(r1), "\n")
  r2 <- try_c(as.data.frame(nanoarrow::read_nanoarrow(bytes))); cat(" nanoarrow:", if (is_err(r2)) r2$msg else nrow(r2), "\n")
  r3 <- try_c(zuarrow::arrow_read(bytes)); cat(" zuarrow:  ", if (is_err(r3)) paste(r3$cls, r3$msg) else nrow(r3), "\n")
}
print(zuarrow::arrow_to_r(h))
