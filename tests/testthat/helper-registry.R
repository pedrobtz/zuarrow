# Puts the registry back as it was when the test ends, so a registration a
# package made at load, such as decimal's "d:*", survives a test that
# replaces or removes it, and one a test loads does not leak (#118).
local_registry <- function(.env = parent.frame()) {
  registry <- zuarrow:::zar_registry
  # Every field but the unload hooks, which local_unload_hooks() restores,
  # and the handlers running now.
  fields <- setdiff(ls(registry), c("hooked", "active"))
  saved <- mget(fields, envir = registry)
  withr::defer(list2env(saved, envir = registry), envir = .env)
}

# A test-only registration stands in for a typed package such as zuint.
local_registration <- function(key, ..., .env = parent.frame()) {
  local_registry(.env = .env)
  arrow_register(key, ...)
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

# The spec of a run-end encoded decimal128(5, 1) field with int32 run ends.
ree_decimal_spec <- function(name = "") {
  zspec(
    "+r",
    name,
    children = list(zspec("i", "run_ends", flags = 0L), zspec("d:5,1"))
  )
}

# A handler for "d:*" that records the format it is given and returns the
# values' exact text.
local_decimal_text <- function(.env = parent.frame()) {
  seen <- new.env()
  seen$formats <- character()
  local_registration(
    "d:*",
    to = function(array, schema) {
      seen$formats <- c(seen$formats, format(schema))
      as.vector(arrow_to_r(array, lossy = "character"))
    },
    .env = .env
  )
  seen
}
