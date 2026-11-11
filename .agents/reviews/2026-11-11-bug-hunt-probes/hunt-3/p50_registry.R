library(zuarrow)
tc <- function(expr) tryCatch(expr, error = function(e) paste0("<", class(e)[1], "> ", conditionMessage(e)))
show <- function(label, x) cat(sprintf("%-46s %s\n", label, paste(capture.output(dput(x)), collapse = "")))
# --- to: pieces combined with c(); one batch vs many
arrow_register("l", to = function(array, schema) structure(arrow_to_r(array, lossy = "allow"), class = "my64"))
df <- data.frame(a = 1:5)
s1 <- function(batch) arrow_stream(df, batch = batch, schema = arrow_schema(structure(list(a = 1), class = "data.frame", row.names = 1L)))
mk <- function(batch) { sch <- .Call(zuarrow:::zar_c_schema_from_spec, list(format = "+s", name = "", flags = 0L, metadata = NULL, children = list(list(format = "l", name = "a", flags = 2L, metadata = NULL, children = list(), dictionary = NULL)), dictionary = NULL)); arrow_stream(df, batch = batch, schema = sch) }
show("to: 1 batch", tc(arrow_to_r(mk(5))$a))
show("to: 3 batches", tc(arrow_to_r(mk(2))$a))
show("to: 0 batches", tc(arrow_to_r(mk(5)[0][0] %||% arrow_stream(df[0, , drop = FALSE], schema = arrow_schema(mk(5))))$a))
# a handler whose pieces differ in type
i <- 0; arrow_register("l", to = function(array, schema) { i <<- i + 1; v <- arrow_to_r(array, lossy = "allow"); if (i %% 2 == 0) as.character(v) else as.integer(v) })
show("to: types vary by batch", tc(arrow_to_r(mk(2))$a))
# factor pieces
arrow_register("l", to = function(array, schema) factor(arrow_to_r(array, lossy = "allow")))
show("to: factor pieces", tc(arrow_to_r(mk(2))$a))
# Date pieces, data frame pieces, matrix pieces, list pieces, NULL
arrow_register("l", to = function(array, schema) data.frame(v = arrow_to_r(array, lossy = "allow")))
show("to: data frame, 1 batch", tc(arrow_to_r(mk(5))$a))
show("to: data frame, 3 batches", tc(arrow_to_r(mk(2))$a))
arrow_register("l", to = function(array, schema) as.list(arrow_to_r(array, lossy = "allow")))
show("to: list pieces 3 batches", tc(arrow_to_r(mk(2))$a))
arrow_register("l", to = function(array, schema) { v <- arrow_to_r(array, lossy = "allow"); names(v) <- letters[seq_along(v)]; v })
show("to: named pieces", tc(arrow_to_r(mk(2))$a))
# error part-way: state afterwards
i <- 0; arrow_register("l", to = function(array, schema) { i <<- i + 1; if (i == 2) stop("boom"); arrow_to_r(array, lossy = "allow") })
st <- mk(2); show("to: error on batch 2", tc(arrow_to_r(st)))
show("  registry active after error", zuarrow:::zar_registry$active)
show("  stream after the failed conversion", tc(arrow_to_r(st)))
# wrong length on one batch but right total
i <- 0; arrow_register("l", to = function(array, schema) { i <<- i + 1; v <- arrow_to_r(array, lossy = "allow"); if (i == 1) c(v, 99) else if (i == 2) v[-1] else v })
show("to: lengths wrong per batch, total right", tc(arrow_to_r(mk(2))$a))
# unregister while a stream that needs the handler is open
arrow_register("l", to = function(array, schema) arrow_to_r(array, lossy = "allow") * 2)
st <- mk(2); b1 <- arrow_next(st); arrow_unregister("l"); b2 <- tc(arrow_next(st)); show("unregister mid-stream: batch1", b1$a); show("  batch2", b2)
arrow_unregister("l")
# --- from: output type or class varies by batch
arrow_register("u", from = function(x) arrow_array(paste0(unclass(x), "/", attr(x, "unit") %||% "?")), class = "tagged")
d <- data.frame(k = 1:4); d$t <- structure(c(1.5, 2.5, 3.5, 4.5), class = "tagged", unit = "kg")
show("from: 1 batch", tc(arrow_to_r(arrow_stream(d))$t))
show("from: 2 batches", tc(arrow_to_r(arrow_stream(d, batch = 2))$t))
show("from: write batch=2", tc(arrow_read(arrow_write(d, NULL, batch = 2))$t))
arrow_register("u", from = function(x) if (length(x) > 2) arrow_array(as.character(unclass(x))) else arrow_array(as.integer(unclass(x))), class = "tagged")
show("from: type varies", tc(arrow_to_r(arrow_stream(d, batch = 2))$t))
arrow_register("u", from = function(x) arrow_array(as.character(unclass(x))[-1]), class = "tagged")
show("from: wrong length", tc(arrow_to_r(arrow_stream(d))$t))
i <- 0; arrow_register("u", from = function(x) { i <<- i + 1; if (i == 3) stop("boom") ; arrow_array(as.character(unclass(x))) }, class = "tagged")
show("from: error on batch 2", tc(arrow_to_r(arrow_stream(d, batch = 2))$t))
f <- tempfile(); i <- 0; show("from: error mid write", tc(arrow_write(d, f, batch = 2))); show("  file left behind", file.exists(f))
# from handler returns one cached handle
cache <- arrow_array(as.character(c(1.5, 2.5, 3.5, 4.5)))
arrow_register("u", from = function(x) cache, class = "tagged")
show("from: cached handle, 1st use", tc(arrow_to_r(arrow_stream(d))$t)); show("  cache after", format(cache)); show("  2nd use", tc(arrow_to_r(arrow_stream(d))$t))
show("  top-level arrow_array identical handle", identical(arrow_array(d$t), cache))
arrow_unregister("u")
# --- straddle ZAR_MAX_PREBUILT
arrow_register("i", from = function(x) arrow_array(as.integer(unclass(x))), class = "myi")
for (n in c(255, 256, 257)) { w <- as.data.frame(setNames(rep(list(structure(1:2, class = "myi")), n), paste0("c", seq_len(n)))); for (k in seq_len(n)) class(w[[k]]) <- "myi"
  show(paste("prebuilt columns", n, "array"), tc(format(arrow_array(w)) > ""))
  show(paste("prebuilt columns", n, "write"), tc(length(arrow_write(w, NULL)) > 0)) }
arrow_unregister("i")
print(arrow_registry())
