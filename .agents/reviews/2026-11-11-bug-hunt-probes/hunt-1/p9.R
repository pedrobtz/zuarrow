source("pre.R")
f <- factor(character(), levels=c("u","v"))
tf <- tempfile(); arrow::write_ipc_stream(data.frame(f=f), tf); str(as.data.frame(arrow::read_ipc_stream(tf)))
str(arrow_read(tf))
# zero-row slice of a stream: batch count
s <- arrow_stream(data.frame(f=f)); print(is.null(arrow_next(s)))
