# flatcc's check_result(x) evaluates x twice on failure: a verification failure at
# nesting depth d costs 2^d evaluations. Corrupt one byte of a deep schema and time the open.
.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zuarrow/3088eef9-0f98-4cb7-ad87-095105df9141/scratchpad/hunt/lib", .libPaths()))
nest <- function(d) { x <- 1L; for (i in seq_len(d)) x <- list(x); x }
mk <- function(d) { df <- data.frame(id = 1L); df$l <- list(nest(d - 1)); zuarrow::arrow_write(df, NULL, format = "stream") }
time_open <- function(b) system.time(tryCatch(zuarrow::arrow_read(b, lazy = TRUE), error = function(e) NULL))[["elapsed"]]
b <- mk(22); len <- readBin(b[5:8], "integer", 1, 4, endian = "little")
hit <- NA
for (at in seq(9, 8 + len)) { bad <- b; bad[at] <- as.raw(0xff); t <- time_open(bad); if (t > 0.15) { hit <- at; cat("depth 22: byte", at, "of", length(b), "-> open took", t, "s\n"); break } }
if (!is.na(hit)) {
  # the same relative corruption at other depths: the field tables are laid out alike, so search again per depth
  for (d in c(24, 26, 28)) { b <- mk(d); len <- readBin(b[5:8], "integer", 1, 4, endian = "little"); best <- 0
    for (at in seq(9, 8 + len)) { bad <- b; bad[at] <- as.raw(0xff); t <- time_open(bad); if (t > best) best <- t; if (t > 0.15 * 2^(d - 22) * 0.5) break }
    cat("depth", d, ": slowest open after one flipped byte:", best, "s  (", length(b), "bytes )\n"); flush.console() }
}
