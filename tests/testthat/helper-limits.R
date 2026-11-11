# Helpers of test-limits.R: the sources one input reaches the reader
# through, and the measure each limit binds at.

# The ways one input reaches the reader, each a function that opens a
# fresh source, and the factor by which the input repeats in it.
limit_sources <- function(bytes, path) {
  writeBin(bytes, path)
  list(
    raw = list(open = function() bytes, times = 1),
    path = list(open = function() path, times = 1),
    connection = list(open = function() file(path), times = 1),
    raw_connection = list(open = function() rawConnection(bytes), times = 1),
    list_raw = list(open = function() list(bytes), times = 1),
    list_mixed = list(
      open = function() list(path, bytes, rawConnection(bytes)),
      times = 3
    )
  )
}

# Reads `source` whole, eagerly or through a lazy stream. A connection the
# caller opened stays open after a read, so it is closed here.
limit_read <- function(source, lazy, limits) {
  on.exit({
    for (con in if (is.list(source)) source else list(source)) {
      if (inherits(con, "connection")) try(close(con), silent = TRUE)
    }
  })
  if (lazy) {
    arrow_to_r(arrow_read(source, lazy = TRUE, limits = limits))
  } else {
    arrow_read(source, limits = limits)
  }
}

# The source kinds a straddle runs on: every kind, or on CRAN, where time
# is short, one of each reader entry (bytes, a path, a list).
limit_kinds <- function(kinds) {
  if (!identical(Sys.getenv("NOT_CRAN"), "true")) {
    kinds <- intersect(kinds, c("raw", "path", "list_mixed"))
  }
  gctorture_sample(kinds, 2L)
}

# Straddles limit `name` at `measure(times)` for an input over every source
# kind and both lazy modes. `measure` takes the number of times a source
# repeats the input, which only max_bytes depends on. Each read's outcome
# is "limit" for a zuarrow_limit_error, "read" for the full result, and
# anything else names what went wrong; one expectation compares them all,
# named by kind, mode and limit value.
expect_straddle <- function(bytes, name, measure, info = NULL) {
  path <- withr::local_tempfile(fileext = ".arrow")
  sources <- limit_sources(bytes, path)
  sources <- sources[limit_kinds(names(sources))]
  outcomes <- character()
  for (kind in names(sources)) {
    s <- sources[[kind]]
    expected <- limit_read(s$open(), FALSE, arrow_limits())
    m <- measure(s$times)
    for (lazy in c(FALSE, TRUE)) {
      for (offset in -1:1) {
        limits <- do.call(arrow_limits, stats::setNames(list(m + offset), name))
        outcome <- tryCatch(
          if (identical(limit_read(s$open(), lazy, limits), expected)) {
            "read"
          } else {
            "a different result"
          },
          zuarrow_limit_error = function(e) "limit",
          error = function(e) class(e)[[1]]
        )
        at <- sprintf("%s, lazy = %s, %s %+d", kind, lazy, name, offset)
        outcomes[[at]] <- outcome
      }
    }
  }
  want <- rep(c("limit", "read", "read"), length(outcomes) / 3)
  expect_identical(
    outcomes,
    stats::setNames(want, names(outcomes)),
    info = info
  )
}

# The largest message part the reader checks against max_message: each
# message's prefixed header and its body, and a file's footer.
message_parts <- function(bytes, format) {
  m <- ipc_messages(bytes, if (format == "file") 8 else 0)
  parts <- c(
    header = max(vapply(m, function(x) x$meta, 0)),
    body = max(vapply(m, function(x) x$body, 0))
  )
  if (format == "file") {
    parts[["footer"]] <- le_read(bytes, length(bytes) - 10, 4)
  }
  parts
}

# Schema nesting as the reader counts it: levels below the top struct.
schema_depth <- function(spec) {
  below <- c(lapply(spec$children, schema_depth), list(0))
  if (!is.null(spec$dictionary)) {
    below <- c(below, list(schema_depth(spec$dictionary)))
  }
  1 + max(unlist(below))
}

# A stream of int32 dictionary 0 holding `sizes[1]` values, then a delta of
# each later size, each followed by a two-row batch that uses it.
delta_stream <- function(sizes) {
  first <- int_dictionary_stream(c(0, 1), c(10, 20))
  schema <- ipc_message_bytes(first, ipc_messages(first)[[1]])
  held <- 0
  parts <- list(schema)
  for (k in seq_along(sizes)) {
    values <- held + seq_len(sizes[[k]])
    parts <- c(
      parts,
      list(
        ipc_int32_dictionary(0, values * 10L, is_delta = k > 1L),
        ipc_dictionary_codes(c(0, held + sizes[[k]] - 1))
      )
    )
    held <- held + sizes[[k]]
  }
  unlist(c(parts, list(ipc_eos())))
}
