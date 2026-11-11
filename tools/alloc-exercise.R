# The workload for .github/workflows/alloc-failure.yaml: r-actions'
# alloc-failure.yml runs it once per allocation, failing a different one
# each time. It runs the paths that allocate and keep native memory across
# an R allocation: the reader, eager and lazy, the writer in each framing
# and codec, conversion both ways with a nested, a factor and a list
# column, and deferred strings. Keep it short; the sweep multiplies it.
#
# Run from the package root, with zuarrow installed. Every error goes to
# the handler below, which prints the condition's class before R stops.
# The workflow's patterns read that line: an injected failure must end in
# a zuarrow condition or R's own allocation error. A failed stopifnot()
# is a wrong result after an absorbed failure, and the sweep reports it.

suppressPackageStartupMessages(library(zuarrow))

withCallingHandlers(
  {
    data <- file.path("tests", "testthat", "data")
    files <- file.path(
      data,
      c("basic.arrow", "basic-zstd.arrows", "two-batches.arrows")
    )

    # The reader: eager, then lazy with arrow_next() to the end.
    for (f in files) {
      df <- arrow_read(f)
      stopifnot(is.data.frame(df), nrow(df) > 0L)
      s <- arrow_read(f, lazy = TRUE)
      n <- 0L
      while (!is.null(b <- arrow_next(s))) {
        n <- n + nrow(b)
      }
      stopifnot(n == nrow(df))
    }

    # Conversion both ways, with a nested, a factor and a list column.
    df <- data.frame(i = 1:3, x = c(1.5, NA, 3))
    df$s <- data.frame(a = c("p", "q", NA), b = c(TRUE, FALSE, NA))
    df$f <- factor(c("a", "b", "a"))
    df$l <- list(1:2, integer(), NULL)
    a <- arrow_array(df)
    back <- arrow_to_r(a)
    stopifnot(identical(back$f, df$f), identical(back$s$a, df$s$a))

    # The writer in each framing and codec, read back.
    for (format in c("file", "stream")) {
      for (codec in c("none", "lz4", "zstd")) {
        bytes <- arrow_write(
          df,
          NULL,
          format = format,
          compression = codec,
          batch = 2L
        )
        stopifnot(identical(arrow_read(bytes)$i, df$i))
      }
    }

    # Deferred strings: an ALTREP vector over the batches, materialised.
    str <- data.frame(t = c("one", "two", NA, "four"))
    lazy <- arrow_to_r(arrow_array(str), copy = FALSE)
    stopifnot(
      identical(as.character(lazy$t), str$t),
      identical(paste(lazy$t), paste(str$t))
    )
  },
  error = function(e) {
    cat(
      "alloc-exercise: ",
      paste(class(e), collapse = "/"),
      "\n",
      sep = "",
      file = stderr()
    )
  }
)
