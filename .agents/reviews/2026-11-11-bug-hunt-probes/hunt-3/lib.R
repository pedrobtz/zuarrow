W <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zuarrow/3088eef9-0f98-4cb7-ad87-095105df9141/scratchpad/hunt"
if (!nzchar(Sys.getenv("DYLD_INSERT_LIBRARIES"))) .libPaths(c(file.path(W, "lib"), .libPaths()))
suppressPackageStartupMessages({library(zuarrow); library(nanoarrow); library(arrow)})
try_c <- function(expr) tryCatch(expr, error = function(e) structure(list(cls = class(e)[1], msg = conditionMessage(e)), class = "err"))
is_err <- function(x) inherits(x, "err")
# arrow Table/RecordBatch -> bytes through zuarrow -> arrow again
via <- function(tab, format = "stream", ...) {
  s <- nanoarrow::as_nanoarrow_array_stream(tab)
  bytes <- zuarrow::arrow_write(s, NULL, format = format, ...)
  if (format == "stream") arrow::read_ipc_stream(bytes, as_data_frame = FALSE) else arrow::read_ipc_file(bytes, as_data_frame = FALSE)
}
check <- function(name, tab, ...) {
  for (fmt in c("stream", "file")) for (comp in c("none", "lz4", "zstd")) {
    r <- try_c(via(tab, fmt, compression = comp, ...))
    if (is_err(r)) { cat(sprintf("ERR  %-28s %s/%s: [%s] %s\n", name, fmt, comp, r$cls, substr(r$msg, 1, 150))); next }
    v <- try_c(r$ValidateFull())
    ok <- !is_err(v) && r$Equals(arrow::as_arrow_table(tab), check_metadata = TRUE) && r$schema$Equals(arrow::as_arrow_table(tab)$schema, check_metadata = TRUE)
    if (!ok) cat(sprintf("DIFF %-28s %s/%s %s\n", name, fmt, comp, if (is_err(v)) v$msg else ""))
    else if (fmt == "stream" && comp == "none") cat(sprintf("ok   %-28s\n", name))
  }
}
