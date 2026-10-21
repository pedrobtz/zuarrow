# A test-only registration stands in for a typed package such as zuint.
local_registration <- function(key, ..., .env = parent.frame()) {
  arrow_register(key, ...)
  withr::defer(arrow_unregister(key), envir = .env)
}

as_text_int64 <- function(array, schema) {
  structure(
    as.vector(arrow_to_r(array, to = character())),
    class = "fake_int64"
  )
}
