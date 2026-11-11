suppressMessages(library(arrow)); k <- as.integer(commandArgs(TRUE)[2]); kind <- commandArgs(TRUE)[1]
t <- int32(); for (i in seq_len(k)) t <- switch(kind, struct = struct(a = t), map = map_of(int32(), t))
tab <- arrow_table(x = concat_arrays(type = t)); f <- sprintf("%s/deep-%s-%d.arrows", commandArgs(TRUE)[3], kind, k)
w <- RecordBatchStreamWriter$create(FileOutputStream$create(f), tab$schema); w$write_table(tab); w$close(); cat(f, "\n")
