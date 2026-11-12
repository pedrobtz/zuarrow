library(zuarrow); library(nanoarrow)
tc <- function(expr) tryCatch(expr, error = function(e) paste0("<", class(e)[1], "> ", substr(conditionMessage(e), 1, 110)))
show <- function(label, x) cat(sprintf("%-52s %s\n", label, paste(capture.output(dput(x)), collapse = "")))
churn <- function() { invisible(gc()); x <- lapply(1:300, function(i) raw(4096)); invisible(gc()) }
df <- data.frame(x = 1:5, s = letters[1:5], f = factor(c("a", "b", "a", "b", "a")))
# write an array, then reuse it
a <- arrow_array(df); b1 <- arrow_write(a, NULL); churn(); b2 <- arrow_write(a, NULL, format = "stream"); b3 <- arrow_write(a, NULL)
show("array reusable after write", identical(b1, b3) && identical(arrow_to_r(a), df) && identical(arrow_read(b2), df))
# write a stream twice
s <- arrow_stream(df, batch = 2); w1 <- arrow_write(s, NULL); w2 <- tc(arrow_write(s, NULL))
show("second write of a consumed stream", if (is.raw(w2)) paste("bytes:", length(w2), "rows:", nrow(arrow_read(w2))) else w2)
show("  format(stream) after", format(s)); show("  as.data.frame after", tc(nrow(as.data.frame(s))))
# failing write leaves what?
s <- arrow_stream(df, batch = 2); p <- file.path(tempdir(), "no-such-dir", "x.arrow"); r <- tc(arrow_write(s, p)); show("write to bad path", r)
show("  stream after failed write: rows left", tc(nrow(as.data.frame(s))))
p <- tempfile(fileext = ".arrow"); writeBin(as.raw(1:10), p)
vs <- arrow_stream(df); 
bad <- .Call(zuarrow:::zar_c_test_failing_stream, arrow_schema(df), FALSE)
r <- tc(arrow_write(bad, p)); show("failing producer -> existing file", r); show("  file untouched", identical(readBin(p, "raw", 100), as.raw(1:10)))
# ended flag vs slot reuse: drain a handle, then move a fresh stream into the same handle
s <- arrow_stream(df, batch = 2); invisible(as.data.frame(s)); show("drained: arrow_next", arrow_next(s))
fresh <- arrow_stream(df, batch = 2)
nanoarrow::nanoarrow_pointer_release(s); nanoarrow::nanoarrow_pointer_move(fresh, s)
show("slot reused: status", .Call(zuarrow:::zar_c_handle_status, s))
show("slot reused: nanoarrow sees rows", { t <- arrow_stream(df, batch = 2); invisible(as.data.frame(t)); nanoarrow::nanoarrow_pointer_release(t); nanoarrow::nanoarrow_pointer_move(arrow_stream(df, batch = 2), t); nrow(nanoarrow::convert_array_stream(t)) })
show("slot reused: zuarrow as.data.frame rows", tc(nrow(as.data.frame(s))))
# a foreign consumer drains part, then zuarrow continues
s <- arrow_stream(df, batch = 2); g <- s$get_next(); show("mixed consumers: rest", tc(as.data.frame(s)$x))
# ended by a foreign consumer, zuarrow asks
s <- arrow_stream(df, batch = 2); while (!is.null(s$get_next())) {} ; show("foreign drained: arrow_next", tc(arrow_next(s)))
# array moved out, R refs dropped
a <- arrow_array(df); dst <- nanoarrow::nanoarrow_allocate_array(); r <- tc(nanoarrow::nanoarrow_pointer_move(a, dst)); show("move array", r)
show("  source after move", format(a)); show("  arrow_to_r(source)", tc(arrow_to_r(a)))
rm(a); churn(); nanoarrow::nanoarrow_array_set_schema(dst, nanoarrow::as_nanoarrow_schema(arrow_schema(df))); show("  moved array reads", identical(arrow_to_r(dst), df))
# export (not move) then drop
a <- arrow_array(df); dst <- nanoarrow::nanoarrow_allocate_array(); nanoarrow::nanoarrow_pointer_export(a, dst); rm(a); churn()
nanoarrow::nanoarrow_array_set_schema(dst, nanoarrow::as_nanoarrow_schema(arrow_schema(df))); show("exported array reads after source dropped", identical(arrow_to_r(dst), df))
# release an array's schema tag, then use the array
a <- arrow_array(df); .Call(zuarrow:::zar_c_test_release, a, TRUE)
show("array with released schema: to_r", tc(arrow_to_r(a))); show("  format", tc(format(a))); show("  write", tc(arrow_write(a, NULL))); show("  schema", tc(format(arrow_schema(a))))
# release twice, print, validate
a <- arrow_array(df); nanoarrow::nanoarrow_pointer_release(a); show("released array: validate", tc(arrow_validate(a))); show("  equal", tc(arrow_equal(a, a))); show("  stream of it", tc(arrow_write(a, NULL)))
sc <- arrow_schema(df); nanoarrow::nanoarrow_pointer_release(sc); show("released schema: arrow_array(schema=)", tc(arrow_array(df, schema = sc))); show("  metadata", tc(arrow_metadata(sc))); show("  arrow_schema()", tc(arrow_schema(sc)))
# stream whose schema handle is released first
s <- arrow_stream(df); sc <- arrow_schema(s); nanoarrow::nanoarrow_pointer_release(sc); show("schema released, stream still reads", identical(as.data.frame(s), df))
cat("p60 done\n")
