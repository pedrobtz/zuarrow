# Writes the IPC files tools/zuarrowlink reads through zuarrow's C API,
# from the same eight columns its C code builds (b, i, l, g, u, z, tdD,
# tsu:UTC), in two batches of 3 and 1 rows:
#
# and repeat-zstd.arrow, 2000 integers that zstd does compress (the small
# buffers of types-zstd.arrow are stored uncompressed, as the format
# allows), which the fixture cannot read without a codec table:
#
#   Rscript tools/make-consumer-fixture.R          # write
#   Rscript tools/make-consumer-fixture.R --check  # fail if they differ
#
# arrow_write() output is byte-identical across platforms (design section
# 6.8), so --check holds the committed files to what this zuarrow writes.
# Run from the package root with zuarrow installed.
consumer_data <- function() {
  df <- data.frame(
    b = c(TRUE, NA, FALSE, TRUE),
    i = c(1L, NA, -2147483647L, 42L),
    l = c(2^53, NA, -1, 0),
    g = c(1.5, NA, -Inf, 0.25),
    u = c("a", NA, "\u00e9", "")
  )
  df$z <- list(as.raw(1:3), NULL, raw(), as.raw(255))
  df$d <- as.Date(c("1970-01-01", NA, "2026-11-27", "1969-12-31"))
  df$t <- as.POSIXct(c(0, NA, 1764201600.5, -1e-6), tz = "UTC")
  df
}

dir <- file.path("tools", "zuarrowlink", "inst", "extdata")
files <- list(
  "types.arrows" = list(format = "stream", compression = "none"),
  "types.arrow" = list(format = "file", compression = "none"),
  "types-zstd.arrow" = list(format = "file", compression = "zstd"),
  "repeat-zstd.arrow" = list(format = "file", compression = "zstd")
)
check <- "--check" %in% commandArgs(trailingOnly = TRUE)
dir.create(dir, recursive = TRUE, showWarnings = FALSE)
stale <- character()
for (name in names(files)) {
  stream <- if (startsWith(name, "repeat")) {
    zuarrow::arrow_stream(data.frame(i = rep(1:4, 500)))
  } else {
    zuarrow::arrow_stream(consumer_data(), batch = 3, schema = c(l = "l"))
  }
  bytes <- zuarrow::arrow_write(
    stream,
    NULL,
    format = files[[name]]$format,
    compression = files[[name]]$compression
  )
  path <- file.path(dir, name)
  if (check) {
    if (!file.exists(path) || !identical(readBin(path, "raw", 1e7), bytes)) {
      stale <- c(stale, name)
    }
  } else {
    writeBin(bytes, path)
  }
}
if (length(stale)) {
  stop(
    "stale consumer fixture files: ",
    paste(stale, collapse = ", "),
    "; run Rscript tools/make-consumer-fixture.R"
  )
}
