# Two compiled thresholds that pick between code paths which must agree:
# the 1 MiB block a connection is read in (zar_connection_block in
# R/read.R), and the 16 validity bitmaps the direct conversion path tracks
# (ZAR_DIRECT_MAX in src/zar_to_r.c). Each is straddled at -1, = and +1.

test_that("a connection reads every byte at each block boundary", {
  sizes <- c(0, 1, block_sizes(1))
  path <- withr::local_tempfile()
  gz <- withr::local_tempfile(fileext = ".gz")
  for (size in sizes) {
    # No period of 2^k, so a block read twice or out of order shows.
    bytes <- as.raw(seq_len(size) %% 251)
    writeBin(bytes, path)
    con <- gzfile(gz, "wb")
    writeBin(bytes, con)
    close(con)
    read <- function(con) {
      zuarrow:::zar_read_connection(con, arrow_limits(), NULL)
    }
    expect_identical(read(file(path)), bytes, info = size)
    expect_identical(read(gzfile(gz)), bytes, info = size)
    con <- rawConnection(bytes)
    expect_identical(read(con), bytes, info = size)
    close(con)
  }
})

test_that("an IPC stream reads through a connection as from its path", {
  sizes <- block_sizes(8)
  path <- withr::local_tempfile(fileext = ".arrows")
  gz <- withr::local_tempfile(fileext = ".arrows.gz")
  for (size in gctorture_sample(sizes, 2L)) {
    bytes <- sized_stream(size)
    writeBin(bytes, path)
    con <- gzfile(gz, "wb")
    writeBin(bytes, con)
    close(con)
    expected <- arrow_read(path)
    expect_identical(arrow_read(file(path)), expected, info = size)
    expect_identical(arrow_read(gzfile(gz)), expected, info = size)
    con <- rawConnection(bytes)
    expect_identical(arrow_read(con), expected, info = size)
    close(con)
    # max_bytes is checked after each block, at the exact total.
    at <- function(limit) {
      arrow_read(file(path), limits = arrow_limits(max_bytes = limit))
    }
    expect_identical(at(size), expected, info = size)
    expect_error(at(size - 1), class = "zuarrow_limit_error")
  }
})

test_that("15, 16 and 17 levels of bitmaps give the element-wise result", {
  for (levels in c(1L, 15L, 16L, 17L)) {
    n <- levels + 1L
    for (type in names(direct_leaves(n))) {
      leaf <- direct_leaves(n)[[type]]
      info <- sprintf("%s, %d levels", type, levels)
      expected <- leaf[[2]]
      expected[seq_len(levels)] <- NA
      direct <- arrow_to_r(direct_nest(levels, leaf[[1]]))
      expect_identical(nest_leaf(direct, levels), expected, info = info)
      if (type != "u") {
        # A dictionary leaf is read through its map, element by element,
        # and must give the same data frame.
        mapped <- arrow_to_r(direct_nest(levels, leaf[[1]], map = TRUE))
        expect_identical(direct, mapped, info = info)
      }
    }
  }
})

test_that("a lossy value is hidden by the outermost of 15, 16 or 17 bitmaps", {
  for (levels in c(15L, 16L, 17L)) {
    n <- levels + 1L
    # int64 values, 2^53 + 1 at one row: the row the outermost struct
    # nulls, so no other level hides it; or the last row, which is valid.
    big <- function(row) {
      values <- lapply(seq_len(n), function(k) le_int(k, 8L))
      values[[row]] <- le_hex("0020000000000001")
      list("l", list(unlist(values)))
    }
    hidden <- arrow_to_r(direct_nest(levels, big(levels)))
    expected <- c(rep(NA_real_, levels), n)
    expect_identical(nest_leaf(hidden, levels), expected, info = levels)
    err <- expect_error(
      arrow_to_r(direct_nest(levels, big(n))),
      class = "zuarrow_lossy_error"
    )
    expect_identical(err$row, as.double(n))
  }
})
