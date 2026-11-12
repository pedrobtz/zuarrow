source("lib.R")
source(file.path(W, "src/tests/testthat/helper-arrays.R"))
S <- test_array_spec
# write a one-column struct batch built from raw buffers; compare arrow's read
# of zuarrow's IPC with arrow's own import of the same handle (C Data Interface)
probe <- function(name, col_spec, col_arr, length, offset = 0, comp = "none") {
  mk <- function() test_array(test_schema(zspec("+s", "", children = list(col_spec))), length, list(NULL), offset = offset, children = list(col_arr))
  ref <- try_c({r <- arrow::as_arrow_array(nanoarrow::as_nanoarrow_array(mk())); r$ValidateFull(); r$field(0L)})
  if (is_err(ref)) { cat(sprintf("REF? %-34s %s\n", name, substr(ref$msg, 1, 120))); ref <- NULL }
  for (fmt in c("stream", "file")) {
    bytes <- try_c(zuarrow::arrow_write(mk(), NULL, format = fmt, compression = comp))
    if (is_err(bytes)) { cat(sprintf("ERR  %-34s %s: [%s] %s\n", name, fmt, bytes$cls, substr(bytes$msg, 1, 110))); next }
    got <- try_c(if (fmt == "stream") arrow::read_ipc_stream(bytes, as_data_frame = FALSE) else arrow::read_ipc_file(bytes, as_data_frame = FALSE))
    if (is_err(got)) { cat(sprintf("ARROW-REJECTS %-25s %s: %s\n", name, fmt, substr(got$msg, 1, 200))); next }
    v <- try_c(got$ValidateFull())
    if (is_err(v)) { cat(sprintf("ARROW-INVALID %-25s %s: %s\n", name, fmt, substr(v$msg, 1, 200))); next }
    show <- function(z) paste(capture.output(print(z))[-(1:2)], collapse = "")
    if (!is.null(ref)) {
      g <- if (got$num_rows == 0 && got$x$num_chunks == 0) NULL else got$x$chunk(0)
      same <- if (is.null(g)) ref$length() == 0 else g$Equals(ref)
      cat(sprintf("%s %-34s %s rows=%d\n", if (same) "ok  " else "DIFF", name, fmt, got$num_rows))
      if (!same) cat("  got:", show(g), "\n  ref:", show(ref), "\n")
    } else { cat(sprintf("read %-34s %s\n", name, fmt)); cat("  got:", show(got$x), "\n") }
    # zuarrow reads its own bytes too
    back <- try_c(zuarrow::arrow_read(bytes, lossy = "allow"))
    if (is_err(back)) cat(sprintf("     self-read: [%s] %s\n", back$cls, substr(back$msg, 1, 100)))
  }
}
i32 <- function(v) S(length(v), list(NULL, le_int(v, 4L)))
str_ <- function(x) S(length(x), c(list(NULL), test_string_buffers(x)))
x <- function(fmt, children = list()) zspec(fmt, "x", children = children)

probe("int32 child longer than batch", x("i"), i32(1:5), 3)
probe("int32 batch offset 2", x("i"), i32(1:5), 3, offset = 2)
probe("utf8 first offset nonzero", x("u"), S(2, list(NULL, le_int(c(2, 3, 5), 4L), charToRaw("abcde"))), 2)
probe("utf8 child offset 1", x("u"), S(2, list(NULL, le_int(c(0, 2, 3, 5), 4L), charToRaw("abcde")), offset = 1), 2)
probe("list first offset nonzero", x("+l", list(zspec("i", "item"))), S(2, list(NULL, le_int(c(1, 3, 5), 4L)), children = list(i32(1:5))), 2)
probe("list child longer than needed", x("+l", list(zspec("i", "item"))), S(2, list(NULL, le_int(c(0, 1, 3), 4L)), children = list(i32(1:5))), 2)
probe("large_list offset", x("+L", list(zspec("i", "item"))), S(2, list(NULL, le_int(c(0, 1, 3, 5), 8L)), offset = 1, children = list(i32(1:5))), 2)
probe("fsl child longer", x("+w:2", list(zspec("i", "item"))), S(2, list(NULL), children = list(i32(1:6))), 2)
probe("fsl child offset", x("+w:2", list(zspec("i", "item"))), S(2, list(NULL), children = list(S(4, list(NULL, le_int(1:6, 4L)), offset = 2))), 2)
probe("struct child longer", x("+s", list(zspec("i", "a"), zspec("u", "b"))), S(2, list(NULL), children = list(i32(1:4), str_(c("p", "q", "r")))), 2)
probe("struct with nulls + offset", x("+s", list(zspec("i", "a"))), S(3, list(test_validity(c(TRUE, FALSE, TRUE, TRUE, FALSE))), null_count = 2, offset = 2, children = list(i32(1:5))), 3)
probe("null type", x("n"), S(3, list()), 3)
probe("null type longer", x("n"), S(5, list()), 3)
probe("null type batch offset", x("n"), S(5, list()), 3, offset = 1)
probe("bool offset 9", x("b"), S(3, list(test_validity(rep(c(TRUE, FALSE, TRUE), 4)), test_bits(rep(c(TRUE, TRUE, FALSE, FALSE), 3))), null_count = -1, offset = 9), 3)
probe("null_count -1", x("i"), S(4, list(test_validity(c(TRUE, FALSE, TRUE, TRUE)), le_int(1:4, 4L)), null_count = -1), 4)
probe("null_count 0 but validity given", x("i"), S(4, list(test_validity(c(TRUE, TRUE, TRUE, TRUE)), le_int(1:4, 4L))), 4)
# intervals
probe("interval months", x("tiM"), S(2, list(NULL, le_int(c(14, -1), 4L))), 2)
probe("interval day_time", x("tiD"), S(2, list(NULL, c(le_int(c(1, 500), 4L), le_int(c(-2, 7), 4L)))), 2)
probe("interval mdn", x("tin"), S(2, list(NULL, c(le_int(1, 4L), le_int(2, 4L), le_int(3, 8L), le_int(-1, 4L), le_int(-2, 4L), le_int(-3, 8L)))), 2)
probe("interval mdn offset", x("tin"), S(1, list(NULL, c(le_int(1, 4L), le_int(2, 4L), le_int(3, 8L), le_int(-1, 4L), le_int(-2, 4L), le_int(-3, 8L))), offset = 1), 1)
# decimals of other widths
probe("decimal32", x("d:5,2,32"), S(2, list(NULL, le_int(c(123, -5), 4L))), 2)
probe("decimal64", x("d:9,2,64"), S(2, list(NULL, le_int(c(123, -5), 8L))), 2)
probe("fixed binary w/ offset", x("w:3"), S(2, list(test_validity(c(TRUE, TRUE, FALSE)), as.raw(1:9)), null_count = 1, offset = 1), 2)
probe("fixed binary width 0", x("w:0"), S(2, list(NULL, raw())), 2)
# views
probe("string_view", x("vu"), S(1, list(NULL, c(le_int(1, 4L), charToRaw("a"), raw(11)), NULL)), 1)
# unions
source(file.path(W, "src/tests/testthat/helper-union.R"))
for (dense in c(TRUE, FALSE)) {
  us <- zspec(if (dense) "+ud:3,7" else "+us:3,7", "x", children = list(zspec("i", "a"), zspec("u", "b")))
  probe(paste("union dense", dense), us, union_ext_array_spec(dense), 4)
  probe(paste("union sliced dense", dense), us, union_ext_array_spec(dense, offset = 1), 3)
  probe(paste("union batch offset dense", dense), us, union_ext_array_spec(dense), 2, offset = 2)
}
# run-end encoded
ree <- function(n, ends, vals, offset = 0) S(n, list(), offset = offset, children = list(S(length(ends), list(NULL, le_int(ends, 4L))), i32(vals)))
rs <- zspec("+r", "x", children = list(zspec("i", "run_ends", flags = 0L), zspec("i", "values")))
probe("ree", rs, ree(5, c(2, 5), c(7, 8)), 5)
probe("ree logical length < last end", rs, ree(3, c(2, 5), c(7, 8)), 3)
probe("ree offset", rs, ree(3, c(2, 5), c(7, 8), offset = 1), 3)
probe("ree under batch offset", rs, ree(5, c(2, 5), c(7, 8)), 3, offset = 1)
probe("ree extra runs", rs, ree(3, c(2, 3, 9), c(7, 8, 9)), 3)
# dictionary
ds <- zspec("i", "x"); ds$dictionary <- zspec("u")
darr <- function(idx, vals, offset = 0, doff = 0, dlen = length(vals) - doff) { s <- S(length(idx) - offset, list(NULL, le_int(idx, 4L)), offset = offset); v <- str_(vals); v$offset <- doff; v$length <- dlen; s$dictionary <- v; s }
probe("dict", ds, darr(c(0, 1, 0), c("a", "b")), 3)
probe("dict values offset", ds, darr(c(0, 1, 0), c("zz", "a", "b"), doff = 1), 3)
probe("dict index offset", ds, darr(c(1, 0, 1, 0), c("a", "b"), offset = 1), 3)
probe("dict empty values, 0 rows", ds, darr(integer(), character()), 0)
