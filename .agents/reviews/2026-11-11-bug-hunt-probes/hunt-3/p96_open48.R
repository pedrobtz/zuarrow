.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zuarrow/3088eef9-0f98-4cb7-ad87-095105df9141/scratchpad/hunt/lib", .libPaths()))
b <- readBin("depth48.arrows", "raw", 1e6); cat("opening\n")
print(system.time(r <- tryCatch(zuarrow::arrow_read(b, lazy = TRUE), error = function(e) conditionMessage(e)))); print(r)
