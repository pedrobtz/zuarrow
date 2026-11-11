.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zuarrow/3088eef9-0f98-4cb7-ad87-095105df9141/scratchpad/hunt/lib-asan", .libPaths()))
suppressPackageStartupMessages(library(zuarrow))
f <- commandArgs(TRUE)[1]; b <- readBin(f, "raw", file.size(f))
t0 <- proc.time()[[3]]
r <- tryCatch(arrow_read(b), error = function(e) class(e)[1])
cat("result", if (is.character(r)) r else "OK", sprintf("[%.2fs]\n", proc.time()[[3]] - t0))
