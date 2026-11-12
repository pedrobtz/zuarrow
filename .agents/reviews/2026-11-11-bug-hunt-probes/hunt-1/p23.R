source("pre.R")
d <- data.frame(i=1:2, s=c("a","b"), d=as.Date(1:2), t=as.POSIXct(1:2, tz="Asia/Tokyo"), f=factor(c("a","b"), ordered=TRUE))
d$l <- list(1L, 2:3); d$st <- data.frame(q=1:2, w=c("x","y")); d$r <- list(as.raw(1), raw())
d$m <- structure(list(data.frame(key="a", value=1L), NULL), arrow_keys_sorted=TRUE)
d0 <- d[0, ]
a <- arrow_to_r(arrow_array(d0)); b <- as.data.frame(arrow_stream(d0)); c2 <- arrow_read(arrow_write(d0, NULL)); c3 <- arrow_read(arrow_write(d0, NULL, format="stream"))
cat("array==stream:", identical(a, b), " stream==ipc:", identical(b, c2), identical(c2, c3), "\n")
for (n in names(d0)) if (!identical(a[[n]], d0[[n]]) || !identical(b[[n]], d0[[n]])) { cat("col", n, ":\n"); dput(d0[[n]]); dput(a[[n]]); dput(b[[n]]) }
m0 <- arrow_stream(matrix(integer(), 0, 3), schema=arrow_matrix()); dput(tr(arrow_to_r(m0, to=arrow_matrix())))
dput(tr(arrow_next(arrow_stream(d0))))
s <- arrow_stream(d0); dput(tr(arrow_validate(s)))
dput(tr(arrow_equal(arrow_stream(d0), arrow_stream(d0))))
