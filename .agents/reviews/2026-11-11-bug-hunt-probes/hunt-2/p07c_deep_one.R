# usage: Rscript p07c_deep_one.R <list|struct|dict|map> <levels>
source("common.R")
args <- commandArgs(TRUE); kind <- args[1]; k <- as.integer(args[2])
st <- function(z) if (is_err(z)) paste0(sub("zuarrow_", "", z$cls), ": ", substr(z$msg, 1, 60)) else paste0("OK ", NROW(z))
nest <- function(k, leaf = arrow::int32()) { t <- leaf; for (i in seq_len(k)) t <- arrow::list_of(t); t }
t <- switch(kind, list = nest(k), struct = { t <- arrow::int32(); for (i in seq_len(k)) t <- arrow::struct(a = t); t },
            dict = nest(k - 1, arrow::dictionary(arrow::int8(), arrow::utf8())),
            map = { t <- arrow::int32(); for (i in seq_len(k)) t <- arrow::map_of(arrow::utf8(), t); t })
a <- tryCatch(arrow::Array$create(NA)$cast(t), error = function(e) arrow::concat_arrays(type = t))
bytes <- a_stream(list(arrow::record_batch(x = a))); writeBin(bytes, sprintf("deep-%s-%d.arrows", kind, k))
cat(sprintf("%-6s levels %4d (%d rows, %d bytes): ", kind, k, length(a), length(bytes)))
t0 <- proc.time()[[3]]
cat("default", st(try_z(arrow_read(bytes))), sprintf("[%.1fs]", proc.time()[[3]] - t0))
cat(" | lazy+next", st(try_z(arrow_next(arrow_read(bytes, lazy = TRUE)))))
for (d in c(k - 1, k, k + 1, k + 2)) cat(" | max_depth", d, st(try_z(arrow_read(bytes, limits = arrow_limits(max_depth = d)))))
cat(" | arrow", st(a_read(bytes)), "\n")
