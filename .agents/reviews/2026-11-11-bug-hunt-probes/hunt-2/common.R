W <- "/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zuarrow/3088eef9-0f98-4cb7-ad87-095105df9141/scratchpad/hunt"
if (!nzchar(Sys.getenv("ZAR_ASAN"))) .libPaths(c(file.path(W, "lib"), .libPaths()))
suppressPackageStartupMessages(library(zuarrow))
try_z <- function(expr) tryCatch(expr, error = function(e) structure(list(cls = class(e)[1], msg = conditionMessage(e)), class = "zerr"))
print.zerr <- function(x, ...) cat("<", x$cls, "> ", x$msg, "\n", sep = "")
is_err <- function(x) inherits(x, "zerr")
# arrow helpers
a_stream <- function(batches, schema = NULL, ...) {
  sink <- arrow::BufferOutputStream$create()
  if (is.null(schema)) schema <- batches[[1]]$schema
  w <- arrow::RecordBatchStreamWriter$create(sink, schema, ...)
  for (b in batches) w$write(b)
  w$close()
  as.raw(sink$finish())
}
a_file <- function(batches, schema = NULL, ...) {
  sink <- arrow::BufferOutputStream$create()
  if (is.null(schema)) schema <- batches[[1]]$schema
  w <- arrow::RecordBatchFileWriter$create(sink, schema, ...)
  for (b in batches) w$write(b)
  w$close()
  as.raw(sink$finish())
}
a_read <- function(bytes) tryCatch({
  r <- if (identical(bytes[1:6], charToRaw("ARROW1"))) arrow::RecordBatchFileReader$create(arrow::BufferReader$create(bytes)) else arrow::RecordBatchStreamReader$create(arrow::BufferReader$create(bytes))
  as.data.frame(r$read_table())
}, error = function(e) structure(list(cls = "arrow_error", msg = substr(conditionMessage(e), 1, 200)), class = "zerr"))
i32 <- function(x) writeBin(as.integer(x), raw(), size = 4, endian = "little")
i64 <- function(x) { lo <- x %% 2^32; hi <- (x - lo) / 2^32; c(writeBin(lo, raw(), size=8, endian="little")[0], packBits(intToBits(bitwAnd(as.integer(lo %% 2^31) , .Machine$integer.max) ) )[0], i64raw(x)) }
i64raw <- function(x) { # x numeric integer-valued, may be negative
  if (x < 0) x <- x + 2^64
  out <- raw(8); for (k in 1:8) { out[k] <- as.raw(x %% 256); x <- x %/% 256 }; out }
i64 <- i64raw
rd32 <- function(b, off) readBin(b[(off+1):(off+4)], "integer", size = 4, endian = "little")
find_bytes <- function(hay, needle) { n <- length(needle); idx <- which(hay == needle[1]); idx <- idx[idx + n - 1 <= length(hay)]; for (k in seq_len(n)[-1]) idx <- idx[hay[idx + k - 1] == needle[k]]; idx - 1 }
# split a stream into messages: list(start, prefix, meta_len, body_len(not known))
a_feather <- function(x, compression = "uncompressed", chunk_size = 65536L) {
  p <- tempfile(); on.exit(unlink(p))
  arrow::write_feather(x, p, compression = compression, chunk_size = chunk_size)
  readBin(p, "raw", file.size(p))
}
# the stream inside a file: bytes 8 .. footer start, plus EOS
file_to_stream <- function(f) {
  n <- length(f); flen <- rd32(f, n - 10)
  c(f[9:(n - 10 - flen)], as.raw(c(255,255,255,255,0,0,0,0)))
}
local({ for (h in c("helper-arrays.R", "helper-read.R", "helper-ipc.R")) sys.source(file.path(W, "src/tests/testthat", h), envir = globalenv()) })
msgs <- function(bytes, pos = 0) ipc_messages(bytes, pos)
mb <- function(bytes, m) ipc_message_bytes(bytes, m)
drain <- function(s, n = 8) { out <- list(); for (k in seq_len(n)) { r <- try_z(arrow_next(s)); out[[k]] <- r; if (is.null(r)) break }; out }
show <- function(x) if (is_err(x)) print(x) else if (is.null(x)) cat("NULL\n") else print(x)
# ---- flatbuffer locator: absolute 0-based positions
fb_tab <- function(bytes, table) {
  so <- le_read(bytes, table, 4); if (so >= 2^31) so <- so - 2^32
  vt <- table - so; slots <- (le_read(bytes, vt, 2) - 4) / 2
  function(id) { if (id >= slots) return(NA); at <- le_read(bytes, vt + 4 + 2 * id, 2); if (at == 0) NA else table + at }
}
fb_ind <- function(bytes, pos) pos + le_read(bytes, pos, 4)   # follow uoffset
# for the message at m$start: positions of interesting fields
locate <- function(bytes, m) {
  fb <- m$start + 8; if (le_read(bytes, m$start, 4) != 2^32 - 1) fb <- m$start + 4
  msg <- fb_tab(bytes, fb_ind(bytes, fb))
  out <- list(body_length = msg(3), type = le_read(bytes, msg(1), 1))
  hdr <- fb_ind(bytes, msg(2))
  rb <- NULL
  if (out$type == 3) rb <- hdr
  if (out$type == 2) { d <- fb_tab(bytes, hdr); out$dict_id <- d(0); out$is_delta <- d(2); rb <- fb_ind(bytes, d(1)) }
  if (!is.null(rb)) {
    t <- fb_tab(bytes, rb); out$length <- t(0)
    nv <- fb_ind(bytes, t(1)); out$n_nodes <- le_read(bytes, nv, 4); out$nodes <- nv + 4      # 16 bytes each: length, null_count
    bv <- fb_ind(bytes, t(2)); out$n_buffers <- le_read(bytes, bv, 4); out$buffers <- bv + 4  # 16 bytes each: offset, length
    out$compression <- t(3)
  }
  out$body <- m$start + m$meta
  out
}
put <- function(bytes, pos, value, n = 8) { bytes[pos + seq_len(n)] <- if (n == 8) i64raw(value) else le_int(value, n); bytes }
get64 <- function(bytes, pos) { v <- le_read(bytes, pos, 8); if (v >= 2^63) v - 2^64 else v }
both <- function(bytes, label, ...) {
  z <- try_z(arrow_read(bytes, ...)); a <- a_read(bytes)
  cat(sprintf("%-46s zuarrow: %s\n%-46s arrow:   %s\n", label,
      if (is_err(z)) paste0("<", z$cls, "> ", substr(z$msg, 1, 90)) else paste("OK", nrow(z), "rows", paste(utils::capture.output(dput(unname(lapply(z, function(c) if (is.factor(c)) as.character(c) else c)), control = NULL)), collapse = "")), "",
      if (is_err(a)) paste0("<err> ", substr(gsub("\n", " ", a$msg), 1, 90)) else paste("OK", nrow(a), "rows", paste(utils::capture.output(dput(unname(lapply(a, function(c) if (is.factor(c)) as.character(c) else c)), control = NULL)), collapse = ""))))
  invisible(z)
}
i64raw <- function(x) {
  neg <- x < 0; if (neg) x <- -x - 1
  out <- raw(8); for (k in 1:8) { out[k] <- as.raw(x %% 256); x <- x %/% 256 }
  if (neg) out <- xor(out, as.raw(255)); out }
i64 <- i64raw
options(arrow.skip_nul = TRUE)
a_read <- function(bytes) tryCatch({
  r <- if (identical(bytes[1:6], charToRaw("ARROW1"))) arrow::RecordBatchFileReader$create(arrow::BufferReader$create(bytes)) else arrow::RecordBatchStreamReader$create(arrow::BufferReader$create(bytes))
  t <- r$read_table(); t$ValidateFull(); as.data.frame(t)
}, error = function(e) structure(list(cls = "arrow_error", msg = substr(conditionMessage(e), 1, 200)), class = "zerr"))
