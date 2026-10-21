# zuarrow handles already inherit from nanoarrow's classes, so nanoarrow's
# generics accept them. These methods make that explicit on zuarrow's own
# classes (D7: methods on the first class only), and are registered when
# nanoarrow loads, so a session without nanoarrow needs nothing from it.

as_nanoarrow_schema.zuarrow_schema <- function(x, ...) {
  NextMethod()
}

as_nanoarrow_array.zuarrow_array <- function(x, ..., schema = NULL) {
  NextMethod()
}

as_nanoarrow_array_stream.zuarrow_array_stream <- function(
  x,
  ...,
  schema = NULL
) {
  NextMethod()
}

zar_s3_register <- function(generic, class, method) {
  package <- strsplit(generic, "::", fixed = TRUE)[[1L]][[1L]]
  name <- strsplit(generic, "::", fixed = TRUE)[[1L]][[2L]]
  register <- function(...) {
    envir <- asNamespace(package)
    if (exists(name, envir = envir, mode = "function")) {
      registerS3method(name, class, method, envir = envir)
    }
  }
  setHook(packageEvent(package, "onLoad"), register)
  if (isNamespaceLoaded(package)) {
    register()
  }
  invisible()
}

.onLoad <- function(libname, pkgname) {
  zar_s3_register(
    "nanoarrow::as_nanoarrow_schema",
    "zuarrow_schema",
    as_nanoarrow_schema.zuarrow_schema
  )
  zar_s3_register(
    "nanoarrow::as_nanoarrow_array",
    "zuarrow_array",
    as_nanoarrow_array.zuarrow_array
  )
  zar_s3_register(
    "nanoarrow::as_nanoarrow_array_stream",
    "zuarrow_array_stream",
    as_nanoarrow_array_stream.zuarrow_array_stream
  )
}
