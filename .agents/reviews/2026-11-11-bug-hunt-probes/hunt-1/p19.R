source("pre.R")
p <- function(l, e) { cat(l, ": "); r <- tr(e); if (inherits(r,"ERR")) print(r) else {dput(r)} }
for (u in list("secs","mins","hours","days","weeks","fortnights","auto","Secs","", NA_character_, c("mins","hours"), NULL, 60))
  p(paste("difftime units", deparse(u)), as.character(arrow_to_r(arrow_array(structure(1, class="difftime", units=u)), lossy="character")))
p("tz NA", format(arrow_schema(structure(1, class=c("POSIXct","POSIXt"), tzone=NA_character_))))
p("tz 5", format(arrow_schema(structure(1, class=c("POSIXct","POSIXt"), tzone=5))))
# fixed_size_binary
a <- arrow_array(list(as.raw(1:2), NULL, as.raw(3:4)), schema="w:2"); print(a)
r <- arrow_to_r(a); dput(r)
print(arrow_array(r)); print(arrow_schema(r))
d <- data.frame(i=1:3); d$w <- r
b <- arrow_write(d, NULL); print(arrow_schema(arrow_read(b, lazy=TRUE))); dput(attributes(arrow_read(b)$w))
p("w wrong length", arrow_array(list(as.raw(1:3)), schema="w:2"))
p("w:2 from chr", arrow_array("ab", schema="w:2"))
grep("arrow_width", readLines(file.path(Sys.getenv("WSRC"), "R/from-r.R")), value=TRUE)
system(paste("grep -rn arrow_width", file.path(Sys.getenv("WSRC"), "R"), file.path(Sys.getenv("WSRC"), "src/*.c"), file.path(Sys.getenv("WSRC"), "NEWS.md"), "| cut -c1-220"))
