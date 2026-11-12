source("pre.R")
f <- factor(c("a",NA,"b"), exclude=NULL); str(f)
a <- arrow_array(f); print(a); r <- arrow_to_r(a); str(r)
str(arrow_read(arrow_write(data.frame(f=f), NULL)))
str(arrow_read(arrow_write(data.frame(f=f), NULL, dictionary=FALSE)))
f2 <- factor(c("a","b")); levels(f2) <- c("a", NA); str(f2)
# true NA level as a level with NA_character_
f3 <- structure(c(1L,2L,NA), levels=c("a",NA), class="factor"); r <- tr(arrow_to_r(arrow_array(f3))); str(r)
# compare: nanoarrow
str(tr(nanoarrow::convert_array(nanoarrow::as_nanoarrow_array(f))))
str(tr(as.vector(arrow::as_arrow_array(f))))
