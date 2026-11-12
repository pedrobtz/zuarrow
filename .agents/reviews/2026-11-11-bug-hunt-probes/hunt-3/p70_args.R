source("lib.R"); source("ipcwalk.R")
tc <- function(expr) tryCatch(expr, error = function(e) paste0("<", class(e)[1], "> ", substr(conditionMessage(e), 1, 100)), warning = function(w) paste0("<warning> ", conditionMessage(w)))
show <- function(label, x) cat(sprintf("%-44s %s\n", label, paste(capture.output(dput(x)), collapse = "")))
df <- data.frame(x = 1:5, s = letters[1:5])
nb <- function(b) if (is.raw(b)) { w <- walk_messages(b); paste(sum(w$msgs$type == "batch"), "batches") } else b
for (b in list(NA, NA_integer_, 0, -1, 1, 2, 5, 6, 2.5, Inf, 2^31, 2^31 - 1, 2^53, 1e308, "2", TRUE, c(1, 2), NULL, 4L, NaN))
  { show(paste("batch =", deparse(b)), nb(tc(zuarrow::arrow_write(df, NULL, format = "stream", batch = b))))
    r <- tc({ s <- zuarrow::arrow_stream(df, batch = b); n <- 0; while (!is.null(s$get_next())) n <- n + 1; n }); show("   arrow_stream batches", r) }
for (comp in c("lz4", "zstd", "none")) for (l in list(NA, 0, -1, 1, 3, 12, 13, 19, 22, 23, 100, -5, -7, -131072, -131073, 1.5, Inf, -Inf, 2^31, "3", TRUE, c(1, 2), .Machine$integer.max, -.Machine$integer.max)) {
  r <- tc(zuarrow::arrow_write(df, NULL, compression = comp, level = l))
  if (is.raw(r)) { a <- tc(as.data.frame(arrow::read_ipc_file(r))); r <- if (is.data.frame(a) && isTRUE(all.equal(a, df, check.attributes = FALSE))) paste("ok", length(r), "bytes") else paste("ARROW:", paste(a, collapse = " ")) }
  show(paste(comp, "level =", deparse(l)), r)
}
print(zukomp::komp_codecs()[, c("id", "level_min", "level_max")])
for (f in list("file", "stream", "FILE", NA, c("stream", "file"), 1, NULL, "str")) show(paste("format =", deparse(f)), { r <- tc(zuarrow::arrow_write(df, NULL, format = f)); if (is.raw(r)) rawToChar(r[1:6][r[1:6] != 0 & r[1:6] < 0x80]) else r })
for (d in list(NA, 1, "TRUE", c(TRUE, FALSE), NULL)) show(paste("dictionary =", deparse(d)), { r <- tc(zuarrow::arrow_write(df, NULL, dictionary = d)); if (is.raw(r)) "bytes" else r })
for (x in list(NA, NA_character_, "", character(), 1, TRUE, c("a", "b"), list())) show(paste("x =", deparse(x)), { r <- tc(zuarrow::arrow_write(df, x)); if (is.raw(r)) "bytes" else r })
# default format by extension
p1 <- tempfile(fileext = ".arrows"); p2 <- tempfile(fileext = ".arrow"); p3 <- tempfile(fileext = ".ARROWS"); p4 <- paste0(tempfile(), ".arrows.bak")
for (p in c(p1, p2, p3, p4)) { zuarrow::arrow_write(df, p); show(paste("ext", sub(".*file[0-9a-f]*", "", p)), rawToChar(readBin(p, "raw", 6)) == "ARROW1") }
con <- rawConnection(raw(), "wb"); zuarrow::arrow_write(df, con); show("connection default format is file", rawToChar(rawConnectionValue(con)[1:6]) == "ARROW1"); show("  open connection left open", isOpen(con)); close(con)
f <- tempfile(); con <- file(f); zuarrow::arrow_write(df, con); show("closed connection is closed again", tc(isOpen(con))); tc(close(con))
con <- file(f, "wt"); show("text-mode connection", tc({zuarrow::arrow_write(df, con); close(con); identical(zuarrow::arrow_read(f), df)}))
con <- file(f, "rb"); show("read-only connection", tc(zuarrow::arrow_write(df, con))); close(con)
con <- gzfile(f, "wb"); zuarrow::arrow_write(df, con); close(con); show("gzfile connection round trip", tc(identical(zuarrow::arrow_read(gzfile(f)), df)))
# append two streams to one connection
con <- file(f, "wb"); zuarrow::arrow_write(df, con, format = "stream"); zuarrow::arrow_write(df, con, format = "stream"); close(con)
show("two streams appended, read back rows", tc(nrow(zuarrow::arrow_read(f)))); show("   arrow rows", tc(nrow(arrow::read_ipc_stream(f))))
