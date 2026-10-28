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

# arrow_register(package = ) adds an onUnload hook for the package once per
# session. Puts the hooks, and zuarrow's record of which packages it has
# hooked, back as they were when the test ends.
local_unload_hooks <- function(packages, .env = parent.frame()) {
  registry <- zuarrow:::zar_registry
  hooked <- registry$hooked
  withr::defer(registry$hooked <- hooked, envir = .env)
  for (name in lapply(packages, packageEvent, event = "onUnload")) {
    old <- getHook(name)
    withr::defer(setHook(name, old, "replace"), envir = .env)
  }
}
