source("pre.R")
cat("locale:", Sys.getlocale("LC_CTYPE"), "\n")
x <- "\xc3\xa9"   # unknown encoding
a <- arrow_to_r(arrow_array(x)); cat(nchar(a, "bytes"), Encoding(a), "\n"); print(charToRaw(a))
Encoding(x) <- "UTF-8"; a <- arrow_to_r(arrow_array(x)); print(charToRaw(a)); print(Encoding(a))
l1 <- "\xe9"; Encoding(l1) <- "latin1"; a <- arrow_to_r(arrow_array(l1)); print(charToRaw(a))
# native unknown invalid
y <- "\xff\xfe"; print(tr(charToRaw(arrow_to_r(arrow_array(y)))))
# factor levels
f <- factor("a"); levels(f) <- "\xc3\xa9"; print(tr(charToRaw(levels(arrow_to_r(arrow_array(f))))))
# names
df <- data.frame(1); names(df) <- "\xc3\xa9"; print(tr(charToRaw(names(arrow_to_r(arrow_array(df))))))
# metadata
s <- arrow_schema("i"); arrow_metadata(s) <- c(k="\xc3\xa9"); print(charToRaw(arrow_metadata(s)))
# arrow_extension
