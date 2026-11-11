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

test_that("a raw vector is read in place, and copied for a lazy handle", {
  df <- basic_df()
  for (name in c("basic.arrow", "basic-zstd.arrows")) {
    bytes <- readBin(test_data(name), raw(), 1e6)
    # Read in place: the deferred strings outlive the input vector.
    out <- arrow_read(bytes, copy = FALSE)
    rm(bytes)
    gc()
    expect_identical(without_metadata(out), df, info = name)
    # A lazy handle keeps its own copy, so it reads after the input is
    # collected.
    bytes <- readBin(test_data(name), raw(), 1e6)
    stream <- arrow_read(bytes, lazy = TRUE)
    rm(bytes)
    gc()
    expect_identical(without_metadata(arrow_to_r(stream)), df, info = name)
  }
})

test_that("a misaligned pre-0.15 raw vector reads like its path", {
  path <- file.path(
    fixtures_dir(),
    "arrow-ipc-stream",
    "integration",
    "0.14.1",
    "generated_primitive.stream"
  )
  bytes <- readBin(path, raw(), file.size(path))
  expect_identical(arrow_read(bytes), arrow_read(path))
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

test_that("max_depth, not the FlatBuffers verifier, refuses a deep schema (#200)", {
  # Lists, structs and maps 47 to 64 levels deep are read and 65 is a limit
  # error. The verifier once ran out of its own nesting budget from 49
  # levels, and its failure path took time exponential in the depth.
  elapsed <- system.time({
    for (kind in c("list", "struct", "map")) {
      for (format in c("file", "stream")) {
        for (depth in c(47L, 48L, 64L)) {
          bytes <- arrow_write(deep_array(kind, depth), NULL, format = format)
          expect_s3_class(arrow_read(bytes), "data.frame")
        }
        bytes <- arrow_write(deep_array(kind, 65L), NULL, format = format)
        expect_error(arrow_read(bytes), class = "zuarrow_limit_error")
        expect_error(
          arrow_read(bytes, limits = arrow_limits(max_depth = 8)),
          class = "zuarrow_limit_error"
        )
        # Past what the verifier checks, whatever max_depth allows.
        bytes <- arrow_write(deep_array(kind, 300L), NULL, format = format)
        expect_error(
          arrow_read(bytes, limits = arrow_limits(max_depth = Inf)),
          class = "zuarrow_limit_error"
        )
      }
    }
  })[["elapsed"]]
  skip_on_cran()
  expect_lt(elapsed, 30)
})

test_that("a limit error names the limit", {
  bytes <- arrow_write(data.frame(x = 1:3))
  expect_snapshot(
    arrow_read(bytes, limits = arrow_limits(max_bytes = 100)),
    error = TRUE
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
  for (k in gctorture_sample(1:200, 20)) {
    mutated <- bytes
    at <- sample(length(bytes), 3)
    mutated[at] <- as.raw(sample(0:255, 3, TRUE))
    # Any error at all is caught, so the check below is the real one: the
    # input reads, or the error has one of the classes hostile bytes may
    # raise, never a bare zuarrow_error or an R error.
    result <- tryCatch(arrow_read(mutated), error = function(e) e)
    outcome <- if (is.data.frame(result)) "data.frame" else class(result)[[1]]
    expect_true(
      outcome %in%
        c(
          "data.frame",
          "zuarrow_format_error",
          "zuarrow_limit_error",
          "zuarrow_codec_error",
          "zuarrow_lossy_error"
        ),
      info = paste(k, outcome)
    )
  }
})

test_that("to, lossy and copy with lazy = TRUE are type errors", {
  path <- test_data("basic.arrow")
  expect_error(
    arrow_read(path, lazy = TRUE, lossy = "allow"),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_read(path, lazy = TRUE, to = list(i = double())),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_read(path, lazy = TRUE, copy = FALSE),
    class = "zuarrow_type_error"
  )
  expect_s3_class(
    arrow_read(path, lazy = TRUE, lossy = "error", copy = TRUE),
    "zuarrow_array_stream"
  )
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

test_that("fields that share a dictionary must share its value type", {
  # Two fields with dictionary id 0 and different value types, one of them
  # large string: the batch was decoded as one type and read as the other.
  expect_error(
    arrow_read(test_path("data", "crash-shared-dictionary.arrow")),
    class = "zuarrow_format_error"
  )
})

test_that("inputs the fuzz target found are refused cleanly", {
  # Each crashed or tripped a sanitizer in zuarrow's reader or the vendored
  # decoder before its fix; crash-expected.csv names the fix each pins.
  files <- list.files(test_path("data"), "^crash-")
  expected <- crash_expected()
  expected <- expected[startsWith(expected$file, "data/"), ]
  expect_setequal(paste0("data/", files), expected$file)
  for (k in seq_len(nrow(expected))) {
    expect_identical(
      crash_outcome(test_path(expected$file[[k]])),
      expected$expect[[k]],
      info = expected$file[[k]]
    )
    expect_true(nzchar(expected$note[[k]]), info = expected$file[[k]])
  }
})

test_that("a field name or metadata key R cannot hold is a format error", {
  df <- data.frame(xQx = 1L)
  for (format in c("file", "stream")) {
    bytes <- arrow_write(df, NULL, format = format, metadata = c(kQk = "v"))
    nul_key <- patch_bytes(bytes, "kQk", as.raw(c(0x6b, 0x00, 0x6b)))
    expect_error(arrow_read(nul_key), class = "zuarrow_format_error")
    bad_key <- patch_bytes(bytes, "kQk", as.raw(c(0x6b, 0xff, 0x6b)))
    expect_error(arrow_read(bad_key), class = "zuarrow_format_error")
    nul_name <- patch_bytes(bytes, "xQx", as.raw(c(0x78, 0x00, 0x78)))
    expect_error(arrow_read(nul_name), class = "zuarrow_format_error")
    bad_name <- patch_bytes(bytes, "xQx", as.raw(c(0x78, 0xff, 0x78)))
    expect_error(arrow_read(bad_name), class = "zuarrow_format_error")
  }
})

test_that("a list of IPC streams reads as one, as Spark Connect sends a result", {
  first <- data.frame(x = 1:3, f = factor(c("a", "b", "a")))
  second <- data.frame(x = 4:5, f = factor(c("c", NA)))
  messages <- list(stream_bytes(first), stream_bytes(second))
  expected <- data.frame(x = 1:5, f = factor(c("a", "b", "a", "c", NA)))

  expect_identical(arrow_read(messages), expected)
  expect_identical(arrow_read(messages, columns = "x"), expected["x"])

  stream <- arrow_read(messages, lazy = TRUE)
  rm(messages)
  gc()
  expect_s3_class(stream, "zuarrow_array_stream")
  expect_identical(arrow_to_r(stream), expected)
})

test_that("a lazy list of streams decodes one batch per arrow_next()", {
  first <- stream_bytes(data.frame(x = 1:2))
  second <- stream_bytes(data.frame(x = 3:4))
  # Cut into the record batch: the schema reads, the batch does not.
  broken <- second[seq_len(length(second) - 16L)]

  stream <- arrow_read(list(first, broken, second), lazy = TRUE)
  expect_identical(arrow_next(stream), data.frame(x = 1:2))
  expect_error(arrow_next(stream), class = "zuarrow_format_error")

  stream <- arrow_read(list(first, second, second), lazy = TRUE, columns = 1)
  expect_identical(arrow_next(stream), data.frame(x = 1:2))
  expect_identical(arrow_next(stream), data.frame(x = 3:4))
  expect_identical(arrow_next(stream), data.frame(x = 3:4))
  expect_null(arrow_next(stream))
  expect_null(arrow_next(stream))
  expect_true(arrow_equal(
    arrow_schema(stream),
    arrow_schema(arrow_read(first, lazy = TRUE))
  ))
})

test_that("a chain takes only readers that own their input", {
  bytes <- stream_bytes(data.frame(x = 1:2))
  chain <- function(readers) {
    zuarrow:::zar_check(.Call(zuarrow:::zar_c_reader_chain, readers))
  }
  open <- function(in_place) {
    .Call(
      zuarrow:::zar_c_reader_open,
      bytes,
      c(2^31, 64, 2^31, Inf, 2^28),
      in_place
    )
  }

  expect_error(chain(list()), class = "zuarrow_type_error")
  expect_error(chain(list(open(TRUE))), class = "zuarrow_handle_error")
  expect_error(
    chain(list(test_stream(arrow_schema(open(FALSE)), list()))),
    class = "zuarrow_handle_error"
  )
  reader <- open(FALSE)
  out <- chain(list(reader))
  expect_error(arrow_next(reader), class = "zuarrow_handle_error")
  expect_identical(arrow_to_r(out), data.frame(x = 1:2))
})

test_that("max_bytes binds a list of sources together, whatever their kind", {
  bytes <- stream_bytes(data.frame(x = 1:2))
  path <- withr::local_tempfile(fileext = ".arrows")
  writeBin(bytes, path)
  limits <- arrow_limits(max_bytes = length(bytes) * 1.5)

  expect_identical(arrow_read(list(path), limits = limits), data.frame(x = 1:2))
  expect_error(
    arrow_read(list(path, path), limits = limits),
    class = "zuarrow_limit_error"
  )
  expect_error(
    arrow_read(list(bytes, path), limits = limits, lazy = TRUE),
    class = "zuarrow_limit_error"
  )
  expect_error(
    arrow_read(list(path, file(path)), limits = limits),
    class = "zuarrow_limit_error"
  )
})

test_that("streams read as one must share a schema and fit the limits", {
  one <- stream_bytes(data.frame(x = 1:2))
  other <- stream_bytes(data.frame(x = c(1.5, 2)))

  expect_error(arrow_read(list(one, other)), class = "zuarrow_format_error")
  expect_error(arrow_read(list()), class = "zuarrow_type_error")
  expect_error(arrow_read(list(one, list())), class = "zuarrow_type_error")
  expect_error(
    arrow_read(list(one, one), limits = arrow_limits(max_bytes = length(one))),
    class = "zuarrow_limit_error"
  )
})

test_that("`columns` that are neither names nor positions are a type error", {
  bytes <- arrow_write(data.frame(x = 1), NULL)
  expect_error(arrow_read(bytes, columns = TRUE), class = "zuarrow_type_error")
  for (columns in list(Inf, -Inf, NaN, NA_integer_, 1e10, c(1, Inf))) {
    expect_no_warning(
      expect_error(
        arrow_read(bytes, columns = columns),
        class = "zuarrow_type_error"
      )
    )
  }
})
