# The registry (design section 6.10): which R class is the exact form of
# which Arrow type. Typed packages register at load and are removed when
# they unload.

zar_registry <- new.env(parent = emptyenv())
zar_registry$entries <- list()
zar_registry$order <- 0L
zar_registry$hooked <- character()
zar_registry$active <- character()

# Formats whose built-in conversion is exact. A registration may make a
# lossy default exact, never an exact default lossy.
zar_exact_formats <- c(
  "n",
  "b",
  "c",
  "C",
  "s",
  "S",
  "i",
  "I",
  "e",
  "f",
  "g",
  "z",
  "Z",
  "vz",
  "u",
  "U",
  "vu",
  "tdD"
)

zar_format_pattern <- paste0(
  "^(n|b|c|C|s|S|i|I|l|L|e|f|g|z|Z|vz|u|U|vu|tdD|tdm|tt[smun]|tD[smun]|",
  "ti[MDn]|d:.+|w:.+|ts[smun]:.*|\\+.*)$"
)

#' Register an exact R type for an Arrow type
#'
#' A typed package, such as 'zuint', 'decimal' or 'zutempo', tells zuarrow
#' which R class is the exact form of an Arrow type. It does so in its
#' `.onLoad()`, when zuarrow is installed; the registration lasts for the
#' session and is removed when that package unloads.
#'
#' The `key` is one of:
#'
#' * an Arrow format string, matched exactly: `"l"` for `int64`;
#' * a prefix pattern ending in `*` for parameterised types: `"d:*"` for
#'   every decimal, `"tsn:*"` for every nanosecond timestamp;
#' * an extension name, such as `"r.decimal"`, which takes precedence over
#'   the storage type's key.
#'
#' `to` converts Arrow to R: a function of `(array, schema)`, the column's
#' array and schema handles, returning an R vector of the array's length.
#' It may be implemented in C against nanoarrow's `r.h` layout. It is called
#' once per batch, and the pieces are combined with `c()`.
#'
#' `from` converts R to Arrow: a function of `(x)` returning an array
#' handle, used for every object that inherits from `class`.
#'
#' Inside `to`, `arrow_to_r()` on the same column uses the built-in
#' conversion, so a handler can start from it.
#'
#' A registration declares whether it is exact. One that is not is used
#' only under `lossy = "warn"` or `"allow"`, and may not replace a type
#' whose built-in conversion is exact. Registering a key again replaces the
#' earlier registration, with a message naming both packages.
#'
#' Registered handlers apply to the top-level columns of a data frame and
#' to the fields of nested data frames, not to the items of a list column.
#'
#' @param key A format string, a prefix pattern or an extension name.
#' @param to `NULL`, or a function of `(array, schema)` returning an R
#'   vector.
#' @param from `NULL`, or a function of `(x)` returning an array handle.
#' @param class The R classes `from` handles.
#' @param package The registering package, so its registrations are removed
#'   when it unloads.
#' @param exact Whether the conversion is exact.
#' @returns `arrow_register()` and `arrow_unregister()` return `key`
#'   invisibly. `arrow_registry()` returns a data frame with columns `key`,
#'   `kind`, `class`, `package` and `exact`.
#' @export
#' @examples
#' arrow_register(
#'   "l",
#'   to = function(array, schema) arrow_to_r(array, to = character()),
#'   exact = TRUE
#' )
#' arrow_registry()
#' arrow_unregister("l")
arrow_register <- function(
  key,
  to = NULL,
  from = NULL,
  class = NULL,
  package = NULL,
  exact = TRUE
) {
  call <- sys.call()
  if (!is.character(key) || length(key) != 1L || is.na(key) || !nzchar(key)) {
    zar_abort("registry", "`key` must be one non-empty string.", call = call)
  }
  if (!is.null(to) && !(is.function(to) && zar_takes(to, 2L))) {
    zar_abort(
      "registry",
      "`to` must be a function of `(array, schema)`.",
      call = call
    )
  }
  if (!is.null(from) && !(is.function(from) && zar_takes(from, 1L))) {
    zar_abort("registry", "`from` must be a function of `(x)`.", call = call)
  }
  if (is.null(to) && is.null(from)) {
    zar_abort(
      "registry",
      "A registration needs `to`, `from` or both.",
      call = call
    )
  }
  if (
    !is.null(from) &&
      (!is.character(class) || length(class) == 0L || anyNA(class))
  ) {
    zar_abort("registry", "`from` needs the R `class` it handles.", call = call)
  }
  if (is.null(from) && !is.null(class)) {
    zar_abort("registry", "`class` needs a `from` handler.", call = call)
  }
  if (!is.logical(exact) || length(exact) != 1L || is.na(exact)) {
    zar_abort("registry", "`exact` must be `TRUE` or `FALSE`.", call = call)
  }
  if (!is.null(package)) {
    if (!is.character(package) || length(package) != 1L || is.na(package)) {
      zar_abort("registry", "`package` must be one package name.", call = call)
    }
    if (!nzchar(system.file(package = package))) {
      zar_abort(
        "dependency",
        sprintf("Package %s is not installed.", package),
        call = call,
        package = package
      )
    }
  }

  kind <- if (endsWith(key, "*")) {
    "pattern"
  } else if (grepl(zar_format_pattern, key)) {
    "format"
  } else {
    "extension"
  }
  prefix <- if (kind == "pattern") sub("\\*$", "", key) else key
  if (!exact && zar_covers_exact(kind, prefix)) {
    zar_abort(
      "registry",
      sprintf(
        "`%s` converts exactly already, so a registration for it must be exact.",
        key
      ),
      call = call
    )
  }

  old <- zar_registry$entries[[key]]
  if (!is.null(old)) {
    message(sprintf(
      "zuarrow: the registration of `%s` by %s replaces the one by %s.",
      key,
      zar_owner(package),
      zar_owner(old$package)
    ))
  }
  zar_registry$order <- zar_registry$order + 1L
  zar_registry$entries[[key]] <- list(
    key = key,
    kind = kind,
    prefix = prefix,
    to = to,
    from = from,
    class = class,
    package = package,
    exact = exact,
    order = zar_registry$order
  )
  if (!is.null(package) && !package %in% zar_registry$hooked) {
    zar_registry$hooked <- c(zar_registry$hooked, package)
    setHook(
      packageEvent(package, "onUnload"),
      function(...) zar_unregister_package(package)
    )
  }
  invisible(key)
}

#' @rdname arrow_register
#' @export
arrow_unregister <- function(key) {
  if (!is.character(key) || length(key) != 1L || is.na(key)) {
    zar_abort("registry", "`key` must be one string.")
  }
  zar_registry$entries[[key]] <- NULL
  invisible(key)
}

#' @rdname arrow_register
#' @export
arrow_registry <- function() {
  entries <- zar_registry$entries
  data.frame(
    key = vapply(entries, `[[`, "", "key", USE.NAMES = FALSE),
    kind = vapply(entries, `[[`, "", "kind", USE.NAMES = FALSE),
    class = vapply(
      entries,
      function(e) paste(e$class, collapse = "/"),
      "",
      USE.NAMES = FALSE
    ),
    package = vapply(
      entries,
      function(e) e$package %||% NA_character_,
      "",
      USE.NAMES = FALSE
    ),
    exact = vapply(entries, `[[`, NA, "exact", USE.NAMES = FALSE),
    stringsAsFactors = FALSE
  )
}

zar_owner <- function(package) {
  if (is.null(package)) "the session" else sprintf("package %s", package)
}

zar_takes <- function(f, n) {
  args <- names(formals(f))
  "..." %in% args || length(args) >= n
}

zar_covers_exact <- function(kind, prefix) {
  if (kind == "extension") {
    return(identical(prefix, "arrow.bool8"))
  }
  if (kind == "format") {
    return(
      prefix %in%
        zar_exact_formats ||
        startsWith(prefix, "w:") ||
        prefix %in% c("+s", "+l", "+L", "+m")
    )
  }
  any(startsWith(c(zar_exact_formats, "w:1", "+s"), prefix))
}

zar_unregister_package <- function(package) {
  entries <- zar_registry$entries
  keep <- vapply(entries, function(e) !identical(e$package, package), NA)
  zar_registry$entries <- entries[keep]
  invisible()
}

# The handler that converts a field to R, or NULL. The extension name
# takes precedence, then the exact format, then the earliest pattern.
zar_handler_for <- function(format, extension) {
  # A handler that calls arrow_to_r() on its own column gets the built-in
  # conversion, not itself again.
  entries <- Filter(
    function(e) !is.null(e$to) && !e$key %in% zar_registry$active,
    zar_registry$entries
  )
  if (length(entries) == 0L) {
    return(NULL)
  }
  if (nzchar(extension)) {
    for (e in entries) {
      if (e$kind == "extension" && identical(e$key, extension)) return(e)
    }
  }
  for (e in entries) {
    if (e$kind == "format" && identical(e$key, format)) return(e)
  }
  patterns <- Filter(function(e) e$kind == "pattern", entries)
  patterns <- patterns[order(vapply(patterns, `[[`, 0L, "order"))]
  for (e in patterns) {
    if (startsWith(format, e$prefix)) return(e)
  }
  NULL
}

# The handler that converts an R object to Arrow, or NULL.
zar_handler_for_class <- function(x) {
  if (!is.object(x)) {
    return(NULL)
  }
  for (e in zar_registry$entries) {
    if (!is.null(e$from) && inherits(x, e$class)) return(e)
  }
  NULL
}

zar_extension_name <- function(spec) {
  value <- spec$metadata[["ARROW:extension:name"]]
  if (is.null(value)) "" else rawToChar(value)
}
