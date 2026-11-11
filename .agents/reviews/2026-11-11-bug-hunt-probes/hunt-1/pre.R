.libPaths(c("/private/tmp/claude-501/-Users-pbtz-src-github-com-pedrobtz-zuarrow/3088eef9-0f98-4cb7-ad87-095105df9141/scratchpad/hunt/lib", .libPaths())); suppressMessages(library(zuarrow))
tr <- function(e) tryCatch(e, error=function(c) structure(list(class(c)[1], conditionMessage(c)), class="ERR"), warning=function(c) structure(list(class(c)[1], conditionMessage(c)), class="ERR"))
print.ERR <- function(x,...) cat("  <", x[[1]], ">", x[[2]], "\n")
chk <- function(label, x, ...) {
  routes <- list(
    array = function() arrow_to_r(arrow_array(x), ...),
    ipc = function() arrow_read(arrow_write(data.frame(v=I(x))[0,,drop=FALSE], NULL)),
    NULL)
  a <- tr(arrow_to_r(arrow_array(x), ...))
  df <- structure(list(v=x), class="data.frame", row.names=.set_row_names(NROW(x)))
  b <- tr(arrow_read(arrow_write(df, NULL), ...)$v)
  c2 <- tr(as.data.frame(arrow_stream(df, batch=2), ...)$v)
  c1 <- tr(as.data.frame(arrow_stream(df, batch=1), ...)$v)
  res <- c(array=identical(a,x), ipc=identical(b,x), s2=identical(c2,x), s1=identical(c1,x))
  cat(sprintf("%-28s %s\n", label, paste(names(res), res, collapse=" ")))
  if (!all(res)) { for (o in list(a,b,c2,c1)[!res][1]) {if (inherits(o,"ERR")) print(o) else {cat("  in : "); dput(x); cat("  out: "); dput(o)}} }
  invisible(res)
}
