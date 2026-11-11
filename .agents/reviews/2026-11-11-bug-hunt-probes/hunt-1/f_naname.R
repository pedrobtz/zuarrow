source("pre.R")
df <- data.frame(x = 1:2); names(df) <- NA_character_
s <- arrow_schema(df); print(s)
a <- arrow_array(df); print(a)
str(arrow_to_r(a))
cat("writing\n")
b <- arrow_write(df, NULL, format = "stream")
str(arrow_read(b))
