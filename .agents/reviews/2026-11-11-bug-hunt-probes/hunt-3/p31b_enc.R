# In a non-UTF-8 locale a native string with bytes outside ASCII is written as the text "<c3><a9>"
library(zuarrow)
x <- rawToChar(as.raw(c(0x63, 0x61, 0x66, 0xc3, 0xa9)))   # "café" as bytes, encoding unknown
cat("locale:", Sys.getlocale("LC_CTYPE"), " input bytes:", paste(charToRaw(x), collapse = " "), "\n")
y <- arrow_to_r(arrow_array(x))
cat("round trip bytes:", paste(charToRaw(y), collapse = " "), "=", y, " nchar", nchar(y, "bytes"), "\n")
bytes <- arrow_write(data.frame(x = x), NULL)
z <- arrow_read(bytes)$x; cat("through IPC:", z, "\n")
x2 <- rawToChar(as.raw(c(0x63, 0xe9)))   # latin1 bytes, unknown encoding: invalid UTF-8
r <- tryCatch(arrow_to_r(arrow_array(x2)), error = function(e) class(e)[1]); cat("invalid bytes:", r, "\n")
