.libPaths(c(Sys.getenv("W_LIB"), .libPaths())); library(zuarrow); x <- "é"; print(charToRaw(arrow_to_r(arrow_array(x)))); print(Sys.getlocale("LC_CTYPE"))
