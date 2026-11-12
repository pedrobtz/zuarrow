source("pre.R")
# nested NA name, and a nanoarrow-built stream whose child has a NULL name
d <- data.frame(a=1:2); inner <- data.frame(x=1:2); names(inner) <- NA_character_; d$s <- inner
r <- tr(arrow_write(d, NULL)); cat("nested NA name:", class(r), "\n")
