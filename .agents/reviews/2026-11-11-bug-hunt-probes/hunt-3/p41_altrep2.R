library(zuarrow)
info <- function(x) .Call(zuarrow:::zar_c_deferred_info, x)
mk <- function(v, batch = 3, ...) arrow_to_r(arrow_stream(data.frame(s = v, stringsAsFactors = FALSE), batch = batch), copy = FALSE, ...)$s
y <- mk(c("b", "a", "d", "c"))
.Call(zuarrow:::zar_c_deferred_probe, y, 3L, 2L, NA_character_)
stopifnot(!is.null(info(y)))
cat("is.na:", is.na(y), "| anyNA:", anyNA(y), "| sort:", sort(y), "| order:", order(y), "| match:", match(NA, y), "| unique:", unique(y), "| table NA:", sum(is.na(factor(y))), "| nchar:", nchar(y), "| which(is.na):", which(is.na(y)), "\n")
# equivalence copy = TRUE vs FALSE over shapes
set.seed(3)
shapes <- list(
  empty = character(), one = "a", nas = rep(NA_character_, 3), mixed = c("a", NA, "", "éé", NA, "long long long", "z"),
  big = sample(c(letters, NA, ""), 1000, TRUE)
)
for (nm in names(shapes)) for (batch in c(1, 2, 3, 1000)) {
  v <- shapes[[nm]]
  a <- mk(v, batch); 
  stopifnot(identical(length(a), length(v)))
  # partial access first, in odd order
  if (length(v) > 2) { stopifnot(identical(a[length(v)], v[length(v)]), identical(a[2], v[2])) }
  stopifnot(identical(is.na(a), is.na(v)), identical(anyNA(a), anyNA(v)))
  stopifnot(identical(sort(a), sort(v)), identical(order(a), order(v)), identical(match(v, a), match(v, v)), identical(unique(a), unique(v)), identical(a == v, v == v), identical(rev(a), rev(v)), identical(nchar(a), nchar(v)))
  stopifnot(identical(a[], v), identical(unserialize(serialize(a, NULL)), v), identical(Encoding(a), Encoding(enc2utf8(v))))
  i <- info(a); stopifnot(is.null(i) || (i$made == length(v) && !i$holds_arrays) || length(v) == 0)
}
# large_string and sliced arrays from a foreign producer
suppressPackageStartupMessages({library(nanoarrow)})
ar <- arrow::Array$create(c("aa", NA, "b", "", "cccc", NA))
for (ty in list(arrow::utf8(), arrow::large_utf8())) for (off in 0:4) {
  sl <- arrow::record_batch(s = ar$cast(ty)$Slice(off, 2))
  h <- nanoarrow::as_nanoarrow_array(sl)
  a <- zuarrow::arrow_to_r(h, copy = FALSE)$s; b <- zuarrow::arrow_to_r(h, copy = TRUE)$s
  stopifnot(identical(a[2:1], b[2:1]), identical(is.na(a), is.na(b)), identical(anyNA(a), anyNA(b)))
  # release the producer's array under a partly-read deferred vector
  a2 <- zuarrow::arrow_to_r(h, copy = FALSE)$s
  if (!is.null(info(a2))) { first <- a2[1]; nanoarrow::nanoarrow_pointer_release(h); invisible(gc())
    r <- tryCatch(a2[2], error = function(e) class(e)[1]); stopifnot(identical(r, "zuarrow_handle_error") || identical(r, b[2])); stopifnot(identical(a2[1], b[1])) }
}
cat("deferred used for sliced foreign arrays:", !is.null(info(zuarrow::arrow_to_r(nanoarrow::as_nanoarrow_array(arrow::record_batch(s = ar$Slice(1, 3))), copy = FALSE)$s)), "\n")
# lossy allow, NUL inside
h <- nanoarrow::as_nanoarrow_array(arrow::record_batch(s = arrow::Array$create(list(as.raw(c(0x61, 0, 0x62)), as.raw(0x63)), type = arrow::binary())$cast(arrow::utf8())))
for (cp in c(TRUE, FALSE)) { r <- tryCatch(suppressWarnings(zuarrow::arrow_to_r(h, copy = cp, lossy = "allow")$s), error = function(e) class(e)[1]); cat("NUL copy", cp, ":", r, "\n") }
for (cp in c(TRUE, FALSE)) { r <- tryCatch(zuarrow::arrow_to_r(h, copy = cp)$s, error = function(e) class(e)[1]); cat("NUL strict copy", cp, ":", r, "\n") }
cat("p41 done\n")
