# Reading IPC, design section 6.7.

test_that("both framings read, plain and compressed", {
  df <- basic_df()
  for (name in c(
    "basic.arrow",
    "basic-lz4.arrow",
    "basic-zstd.arrow",
    "basic.arrows",
    "basic-zstd.arrows",
    "two-batches.arrows"
  )) {
    expect_identical(
      without_metadata(arrow_read(test_data(name))),
      df,
      info = name
    )
  }
})

test_that("schema metadata becomes the frame's arrow_metadata", {
  metadata <- attr(arrow_read(test_data("basic.arrow")), "arrow_metadata")
  expect_identical(metadata[["origin"]], "zuarrow tests")
})

test_that("a raw vector and a connection read like the path", {
  df <- basic_df()
  bytes <- readBin(test_data("basic.arrow"), raw(), 1e6)
  expect_identical(without_metadata(arrow_read(bytes)), df)
  expect_identical(
    without_metadata(arrow_read(file(test_data("basic.arrows")))),
    df
  )
  gz <- withr::local_tempfile(fileext = ".arrows.gz")
  con <- gzfile(gz, "wb")
  writeBin(readBin(test_data("basic.arrows"), raw(), 1e6), con)
  close(con)
  expect_identical(without_metadata(arrow_read(gzfile(gz))), df)
})

test_that("columns selects by name or position, in the order given", {
  df <- basic_df()
  out <- arrow_read(test_data("basic.arrow"), columns = c("s", "i"))
  expect_identical(without_metadata(out), df[c("s", "i")])
  out <- arrow_read(test_data("basic.arrows"), columns = c(4, 1))
  expect_identical(without_metadata(out), df[c("f", "i")])
  expect_error(
    arrow_read(test_data("basic.arrow"), columns = "nope"),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_read(test_data("basic.arrow"), columns = 9),
    class = "zuarrow_type_error"
  )
})

test_that("lazy returns a stream read batch by batch", {
  stream <- arrow_read(test_data("two-batches.arrows"), lazy = TRUE)
  expect_s3_class(stream, "zuarrow_array_stream")
  rows <- 0L
  while (!is.null(batch <- arrow_next(stream))) {
    rows <- rows + nrow(batch)
  }
  expect_identical(rows, 4L)
  expect_null(arrow_next(stream))
})

test_that("a lazy stream crosses to nanoarrow", {
  skip_if_not_installed("nanoarrow")
  stream <- arrow_read(test_data("basic.arrows"), lazy = TRUE)
  out <- as.data.frame(nanoarrow::as_nanoarrow_array_stream(stream))
  expect_identical(out$i, basic_df()$i)
})

test_that("conversion options pass through", {
  out <- arrow_read(test_data("basic.arrow"), to = list(i = character()))
  expect_identical(as.vector(out$i), c("1", NA, "3", "4"))
})

test_that("limits bind before the bytes are used", {
  path <- test_data("basic.arrow")
  expect_error(
    arrow_read(path, limits = arrow_limits(max_bytes = 100)),
    class = "zuarrow_limit_error"
  )
  bytes <- readBin(path, raw(), 1e6)
  expect_error(
    arrow_read(bytes, limits = arrow_limits(max_bytes = 100)),
    class = "zuarrow_limit_error"
  )
  expect_error(
    arrow_read(file(path), limits = arrow_limits(max_bytes = 100)),
    class = "zuarrow_limit_error"
  )
  expect_error(
    arrow_read(path, limits = arrow_limits(max_message = 64)),
    class = "zuarrow_limit_error"
  )
  expect_error(
    arrow_read(path, limits = arrow_limits(max_batch_rows = 2)),
    class = "zuarrow_limit_error"
  )
  expect_error(
    arrow_read(path, limits = arrow_limits(max_depth = 0)),
    class = "zuarrow_limit_error"
  )
})

test_that("a compressed buffer claiming too much is a limit error", {
  # Each compressed buffer's prefix is checked against max_message before
  # anything is allocated for it; the header fits, the claim does not.
  expect_error(
    arrow_read(
      test_data("basic-zstd.arrows"),
      limits = arrow_limits(max_message = 20)
    ),
    class = "zuarrow_limit_error"
  )
})

test_that("malformed input is a format error", {
  bytes <- readBin(test_data("basic.arrow"), raw(), 1e6)
  stream <- readBin(test_data("basic.arrows"), raw(), 1e6)
  cases <- list(
    empty = raw(),
    noise = as.raw(1:64),
    file_cut = bytes[seq_len(length(bytes) - 20)],
    file_magic_only = c(
      charToRaw("ARROW1"),
      as.raw(c(0, 0)),
      charToRaw("ARROW1")
    ),
    stream_cut = stream[seq_len(200)],
    stream_body_cut = stream[seq_len(length(stream) - 30)]
  )
  for (name in names(cases)) {
    expect_error(
      arrow_read(cases[[name]]),
      class = "zuarrow_format_error",
      info = name
    )
  }
})

test_that("flipped bytes never crash the reader", {
  withr::local_seed(20261021)
  bytes <- readBin(test_data("basic-zstd.arrow"), raw(), 1e6)
  for (k in 1:200) {
    mutated <- bytes
    at <- sample(length(bytes), 3)
    mutated[at] <- as.raw(sample(0:255, 3, TRUE))
    result <- tryCatch(arrow_read(mutated), zuarrow_error = function(e) e)
    expect_true(is.data.frame(result) || inherits(result, "zuarrow_error"))
  }
})

test_that("a missing path is an io error", {
  expect_error(arrow_read(tempfile()), class = "zuarrow_io_error")
  expect_error(arrow_read(tempdir()), class = "zuarrow_io_error")
})

test_that("bad arguments are type errors", {
  expect_error(arrow_read(1), class = "zuarrow_type_error")
  expect_error(
    arrow_read(test_data("basic.arrow"), lazy = NA),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_read(test_data("basic.arrow"), limits = list()),
    class = "zuarrow_type_error"
  )
  expect_error(arrow_limits(max_bytes = -1), class = "zuarrow_type_error")
})

test_that("arrow reads what arrow wrote, the same way", {
  skip_if_not_installed("arrow")
  path <- test_data("basic-zstd.arrow")
  ours <- without_metadata(arrow_read(path))
  theirs <- as.data.frame(arrow::read_feather(path))
  expect_identical(ours$s, theirs$s)
  expect_identical(ours$d, theirs$d)
})

test_that("inputs the fuzz target found are refused cleanly", {
  # Each crashed or tripped a sanitizer in zuarrow's reader or the vendored
  # decoder before its fix (tools/patches/0005 to 0012, and the reader's own
  # footer, field-node, alignment and view checks).
  files <- list.files(test_path("data"), "^crash-", full.names = TRUE)
  expect_gte(length(files), 10L)
  for (f in files) {
    result <- tryCatch(
      arrow_read(f, lossy = "allow"),
      zuarrow_error = function(e) e
    )
    expect_true(
      is.data.frame(result) ||
        inherits(
          result,
          c(
            "zuarrow_format_error",
            "zuarrow_limit_error",
            "zuarrow_codec_error"
          )
        ),
      info = basename(f)
    )
  }
})
