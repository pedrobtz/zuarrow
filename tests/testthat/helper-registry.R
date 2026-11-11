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

# A stream of `df`'s rows in batches of `batch`, with each column's format
# replaced by the one `formats` names, at the top or, with `field`, inside
# that struct column (#198).
retyped_stream <- function(df, formats, batch, field = NULL) {
  spec <- .Call(zuarrow:::zar_c_schema_to_spec, arrow_schema(df))
  retype <- function(spec) {
    for (k in seq_along(spec$children)) {
      to <- formats[[spec$children[[k]]$name]]
      if (!is.null(to)) {
        spec$children[[k]]$format <- to
      }
    }
    spec
  }
  if (is.null(field)) {
    spec <- retype(spec)
  } else {
    k <- match(field, names(df))
    spec$children[[k]] <- retype(spec$children[[k]])
  }
  arrow_stream(df, batch = batch, schema = test_schema(spec))
}

# Registers a `to` handler of each shape a family package uses: a plain
# class over a base vector, a factor, a class with an attribute, a data
# frame from a struct and a handler that takes the lossy policy (#198).
local_handler_shapes <- function(.env = parent.frame()) {
  local_registration("l", to = as_text_int64, .env = .env)
  local_registration(
    "u",
    to = function(array, schema) {
      factor(arrow_to_r(array), levels = c("c", "b", "a"))
    },
    .env = .env
  )
  local_registration(
    "s",
    to = function(array, schema) {
      structure(as.double(arrow_to_r(array)), class = "fake_unit", unit = "kg")
    },
    .env = .env
  )
  local_registration(
    "zar.test.point",
    to = function(array, schema) {
      out <- arrow_to_r(array)
      out$x <- structure(as.character(out$x), class = "fake_int64")
      out
    },
    .env = .env
  )
  local_registration(
    "L",
    to = function(array, schema, lossy) {
      out <- arrow_to_r(array, lossy = "allow")
      structure(out, class = "fake_uint64", lossy = lossy)
    },
    .env = .env
  )
}

# Rows of every column local_handler_shapes() handles, before retyping.
handler_shapes_frame <- function() {
  df <- data.frame(
    a = c(1L, NA, 3L, 4L, 5L),
    f = c("a", "b", NA, "c", "a"),
    u = c(10L, 20L, NA, 40L, 50L),
    w = c(7L, 8L, 9L, NA, 11L)
  )
  df$p <- data.frame(x = c(1L, 2L, 3L, NA, 5L), y = c("v", NA, "x", "y", "z"))
  attr(df$p, "arrow_extension") <- "zar.test.point"
  df
}
