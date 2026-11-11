.libPaths(c(Sys.getenv("W_LIB"), .libPaths())); suppressMessages(library(zuarrow))
a <- commandArgs(TRUE); f <- a[1]; lim <- if (length(a) > 1) arrow_limits(max_depth = as.numeric(a[2])) else arrow_limits()
b <- readBin(f, "raw", file.size(f)); t <- system.time(r <- tryCatch({arrow_read(b, limits = lim); "read"}, error = function(e) class(e)[1]))
cat(basename(f), length(b), "bytes:", r, round(t[["elapsed"]], 2), "s\n")
