.libPaths(c(Sys.getenv("W_LIB"), .libPaths())); library(zuarrow); df <- data.frame(x = 1:2); names(df) <- NA_character_; arrow_write(df, NULL)
