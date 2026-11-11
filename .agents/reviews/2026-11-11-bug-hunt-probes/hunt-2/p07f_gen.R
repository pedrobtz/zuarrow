source("common.R")
nest <- function(k) { t <- arrow::int32(); for (i in seq_len(k)) t <- arrow::list_of(t); t }
for (k in as.integer(commandArgs(TRUE))) writeBin(a_stream(list(arrow::record_batch(x = arrow::concat_arrays(type = nest(k))))), sprintf("deep-list-%d.arrows", k))
