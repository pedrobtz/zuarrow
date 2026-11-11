# Helpers of test-thresholds.R: inputs sized to the connection block,
# and nests of validity bitmaps for the direct conversion path.

# The sizes `step` around the end of the first connection block, and on a
# check other than CRAN's, at and past the end of the second, where blocks
# are joined.
block_sizes <- function(step) {
  block <- zuarrow:::zar_connection_block
  sizes <- c(block - step, block, block + step)
  if (identical(Sys.getenv("NOT_CRAN"), "true")) {
    sizes <- c(sizes, 2 * block, 2 * block + step)
  }
  sizes
}

# A stream of one binary column whose bytes are exactly `size`, a multiple
# of 8, without the end-of-stream marker, so its last bytes are data the
# batch needs.
sized_stream <- function(size) {
  one <- function(n) {
    df <- data.frame(id = 1L)
    df$b <- list(as.raw(seq_len(n) %% 251))
    bytes <- arrow_write(df, NULL, format = "stream")
    bytes[seq_len(length(bytes) - 8L)]
  }
  # The headers keep their size; the body grows with the value, padded to
  # 8 bytes.
  base <- length(one(8))
  bytes <- one(8 + size - base)
  stopifnot(length(bytes) == size)
  bytes
}

# Column `x` of a batch of `levels + 1` rows: `levels - 1` structs around
# leaf `leaf`, every level holding a validity bitmap. Level j, the leaf
# being level 1 and the outermost struct level `levels`, is null at row j;
# the last row is valid throughout. `leaf` is list(format, buffers): the
# leaf's data buffers without validity. With `map = TRUE` the leaf is a
# dictionary over those values, which forces the element-wise path.
direct_nest <- function(levels, leaf, map = FALSE) {
  n <- levels + 1L
  valid <- function(j) seq_len(n) != j
  if (map) {
    spec <- zspec("i", "x")
    spec$dictionary <- zspec(leaf[[1]])
    arr <- test_array_spec(
      n,
      list(test_validity(valid(1L)), le_int(seq_len(n) - 1L, 4L)),
      null_count = 1,
      dictionary = test_array_spec(n, c(list(NULL), leaf[[2]]))
    )
  } else {
    spec <- zspec(leaf[[1]], "x")
    arr <- test_array_spec(
      n,
      c(list(test_validity(valid(1L))), leaf[[2]]),
      null_count = 1
    )
  }
  for (j in seq_len(levels - 1L) + 1L) {
    spec <- zspec("+s", paste0("s", j), children = list(spec))
    arr <- test_array_spec(
      n,
      list(test_validity(valid(j))),
      null_count = 1,
      children = list(arr)
    )
  }
  test_array(
    test_schema(zspec("+s", children = list(spec))),
    n,
    list(NULL),
    children = list(arr)
  )
}

# The leaf vector of a converted direct_nest().
nest_leaf <- function(df, levels) {
  x <- df
  for (j in seq_len(levels - 1L)) {
    x <- x[[1]]
  }
  x$x
}

direct_leaves <- function(n) {
  strings <- paste0("v", seq_len(n))
  offsets <- c(0, cumsum(nchar(strings)))
  list(
    i = list(list("i", list(le_int(seq_len(n) * 10, 4L))), seq_len(n) * 10L),
    g = list(
      list("g", list(writeBin(seq_len(n) / 4, raw(), endian = "little"))),
      seq_len(n) / 4
    ),
    b = list(
      list("b", list(test_validity(seq_len(n) %% 2 == 0))),
      seq_len(n) %% 2 == 0
    ),
    u = list(
      list(
        "u",
        list(le_int(offsets, 4L), charToRaw(paste(strings, collapse = "")))
      ),
      strings
    )
  )
}
