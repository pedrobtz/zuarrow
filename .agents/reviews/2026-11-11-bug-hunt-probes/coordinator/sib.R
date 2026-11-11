.libPaths(c(Sys.getenv("W_LIB"), .libPaths())); suppressMessages(library(zuarrow))
t_ <- function(label, expr) { r <- tryCatch(expr, error = function(e) paste0("<", class(e)[1], "> ", conditionMessage(e))); cat("##", label, ": "); str(r) }
# F2 siblings: field metadata and schema metadata keys with NUL
d <- data.frame(a = 1:2); attr(d$a, "arrow_field_metadata") <- list(k = as.raw(c(0x61, 0, 0x62)))
t_("F2 field metadata value", attr(arrow_read(arrow_write(d, NULL))$a, "arrow_field_metadata"))
t_("F2 C interface keeps NUL", { s <- arrow_schema(data.frame(a = 1)); arrow_metadata(s) <- list(k = as.raw(c(0x61, 0, 0x62))); arrow_metadata(nanoarrow::as_nanoarrow_schema(s)) })
t_("F2 nanoarrow::write_nanoarrow same input", { s <- arrow_schema(data.frame(a = 1)); arrow_metadata(s) <- list(k = as.raw(c(0x61, 0, 0x62))); NULL })
# F1 siblings: NA name on a nested struct field, on a list<struct> element field
d2 <- data.frame(a = 1:2); d2$s <- data.frame(q = 1:2); names(d2$s) <- NA_character_
t_("F1 nested struct NA name", length(arrow_write(d2, NULL)))
