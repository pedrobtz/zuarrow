# Writing IPC, design section 6.8.

test_that("every framing and codec round-trips", {
  df <- basic_df()
  for (format in c("file", "stream")) {
    for (compression in c("none", "lz4", "zstd")) {
      bytes <- arrow_write(
        df,
        NULL,
        format = format,
        compression = compression,
        batch = 3
      )
      expect_type(bytes, "raw")
      expect_identical(
        without_metadata(arrow_read(bytes)),
        df,
        info = paste(format, compression)
      )
    }
  }
})

test_that("the file format has its magic and the stream its end marker", {
  df <- basic_df()
  file <- arrow_write(df, NULL)
  expect_identical(file[1:6], charToRaw("ARROW1"))
  expect_identical(utils::tail(file, 6), charToRaw("ARROW1"))
  stream <- arrow_write(df, NULL, format = "stream")
  expect_false(identical(stream[1:6], charToRaw("ARROW1")))
  expect_identical(
    utils::tail(stream, 8),
    as.raw(c(255, 255, 255, 255, 0, 0, 0, 0))
  )
})

test_that("the path's extension picks the default framing", {
  df <- basic_df()
  arrows <- withr::local_tempfile(fileext = ".arrows")
  arrow <- withr::local_tempfile(fileext = ".arrow")
  expect_identical(arrow_write(df, arrows), arrows)
  arrow_write(df, arrow)
  expect_false(identical(readBin(arrows, raw(), 6), charToRaw("ARROW1")))
  expect_identical(readBin(arrow, raw(), 6), charToRaw("ARROW1"))
  expect_identical(without_metadata(arrow_read(arrows)), df)
})

test_that("a connection is written to", {
  path <- withr::local_tempfile()
  arrow_write(basic_df(), file(path))
  expect_identical(without_metadata(arrow_read(path)), basic_df())
})

test_that("batch splits a data frame into record batches", {
  stream <- arrow_read(arrow_write(basic_df(), NULL, batch = 1), lazy = TRUE)
  n <- 0L
  while (!is.null(arrow_next(stream))) {
    n <- n + 1L
  }
  expect_identical(n, 4L)
})

test_that("factors are dictionaries, or strings with dictionary = FALSE", {
  df <- data.frame(
    f = factor(c("b", "a", NA), levels = c("b", "a")),
    o = factor("x", ordered = TRUE)
  )
  expect_identical(without_metadata(arrow_read(arrow_write(df, NULL))), df)
  plain <- without_metadata(arrow_read(arrow_write(
    df,
    NULL,
    dictionary = FALSE
  )))
  expect_identical(plain$f, c("b", "a", NA))
})

test_that("metadata becomes schema metadata, attributes field metadata", {
  df <- data.frame(x = 1:2)
  attr(df$x, "arrow_field_metadata") <- c(unit = "kg")
  out <- arrow_read(arrow_write(df, NULL, metadata = c(origin = "test")))
  expect_identical(attr(out, "arrow_metadata"), c(origin = "test"))
  expect_identical(attr(out$x, "arrow_field_metadata"), c(unit = "kg"))
})

test_that("arrays and streams are written as they are", {
  df <- basic_df()
  expect_identical(
    without_metadata(arrow_read(arrow_write(arrow_array(df), NULL))),
    df
  )
  expect_identical(
    without_metadata(arrow_read(arrow_write(
      arrow_stream(df, batch = 2),
      NULL
    ))),
    df
  )
})

test_that("writing an array leaves it usable", {
  df <- data.frame(x = 1:3, s = c("a", "b", NA))
  array <- arrow_array(df)
  deferred <- arrow_to_r(array, copy = FALSE)
  first <- arrow_write(array, NULL)
  expect_identical(arrow_write(array, NULL), first)
  expect_identical(arrow_to_r(array), df)
  expect_identical(deferred, df)
  gc()
  expect_identical(without_metadata(arrow_read(first)), df)
})

test_that("writing a released array is a handle error", {
  array <- arrow_array(data.frame(x = 1:3))
  stream <- .Call(zar_c_stream_from_arrays, arrow_schema(array), list(array))
  expect_error(arrow_write(array, NULL), class = "zuarrow_handle_error")
})

test_that("nested and list columns are written", {
  df <- data.frame(id = 1:3)
  df$pos <- data.frame(x = c(1, 2, 3))
  df$tags <- list("a", NULL, c("b", "c"))
  expect_identical(
    without_metadata(arrow_read(arrow_write(df, NULL, compression = "zstd"))),
    df
  )
})

test_that("an unknown null count is computed before it is written", {
  # The C Data Interface allows null_count = -1; a FieldNode does not.
  batch <- test_array(
    test_schema(zspec("+s", children = list(zspec("i", "x")))),
    3,
    list(NULL),
    children = list(test_array_spec(
      3,
      list(as.raw(0x05), le_int(c(1, 2, 3), 4L)),
      null_count = -1
    ))
  )
  for (format in c("file", "stream")) {
    out <- arrow_read(arrow_write(batch, NULL, format = format))
    expect_identical(out$x, c(1L, NA, 3L), info = format)
  }
})

test_that("an incompressible buffer is written as it is", {
  withr::local_seed(1)
  df <- data.frame(x = stats::runif(1000))
  out <- arrow_write(df, NULL, compression = "lz4")
  expect_identical(without_metadata(arrow_read(out)), df)
})

test_that("compression levels are passed to the codec", {
  df <- data.frame(s = rep(c("abc", "defg"), 500))
  fast <- arrow_write(df, NULL, compression = "zstd", level = 1)
  best <- arrow_write(df, NULL, compression = "zstd", level = 19)
  expect_identical(without_metadata(arrow_read(fast)), df)
  expect_identical(without_metadata(arrow_read(best)), df)
})

test_that("the same input gives the same bytes", {
  # A leg whose bytes differ fails here: the hashes are the platform-free
  # output of the fixed input (design section 6.8).
  df <- determinism_df()
  expect_identical(
    md5_of(arrow_write(df, NULL, batch = 3)),
    "b300e74a4f36f6a85a0bae94582024c8"
  )
  expect_identical(
    md5_of(arrow_write(df, NULL, format = "stream", batch = 3)),
    "764227ecde9140d0907bcdfea03ac8fd"
  )
  expect_identical(
    md5_of(arrow_write(df, NULL, compression = "lz4", batch = 3)),
    "91190b836a4a6e1f48a23e15a3461770"
  )
  expect_identical(
    md5_of(arrow_write(df, NULL, compression = "zstd", batch = 3)),
    "67e26b55dd346508c43c6125a7628f6a"
  )
})

test_that("a stream with changing dictionaries is written only as a stream", {
  schema <- arrow_schema(factor("a"))
  batch <- function(levels) {
    test_array(
      test_schema(zspec(
        "+s",
        children = list(c(
          .Call(zuarrow:::zar_c_schema_to_spec, schema)[c(
            "format",
            "flags",
            "metadata",
            "children",
            "dictionary"
          )],
          name = "f"
        ))
      )),
      1,
      list(NULL),
      children = list(test_array_spec(
        1,
        list(NULL, le_int(0, 4L)),
        dictionary = test_array_spec(
          1,
          list(NULL, le_int(c(0, nchar(levels)), 4L), charToRaw(levels))
        )
      ))
    )
  }
  make <- function() {
    s1 <- batch("a")
    test_stream(arrow_schema(s1), list(s1, batch("b")))
  }
  out <- arrow_read(arrow_write(make(), NULL, format = "stream"))
  expect_identical(as.character(out$f), c("a", "b"))
  expect_error(
    arrow_write(make(), NULL, format = "file"),
    class = "zuarrow_type_error"
  )
})

test_that("bad arguments are type errors", {
  expect_error(arrow_write(1:3, NULL), class = "zuarrow_type_error")
  expect_error(arrow_write(basic_df(), 1), class = "zuarrow_type_error")
  expect_error(
    arrow_write(basic_df(), NULL, level = 1.5),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_write(basic_df(), NULL, dictionary = NA),
    class = "zuarrow_type_error"
  )
  expect_error(arrow_write(basic_df(), NULL, compression = "gzip"))
  expect_error(
    arrow_write(basic_df(), file.path(tempfile(), "no", "dir.arrow")),
    class = "zuarrow_io_error"
  )
})

# Oracle 4 (design section 9): arrow reads what zuarrow writes, at every
# option, and zuarrow reads what arrow writes.
test_that("arrow reads what arrow_write() writes", {
  skip_if_not_installed("arrow")
  skip_if_not(
    arrow::codec_is_available("zstd") && arrow::codec_is_available("lz4_frame"),
    "arrow was built without its codecs"
  )
  df <- basic_df()
  for (compression in c("none", "lz4", "zstd")) {
    file <- arrow_write(df, NULL, compression = compression)
    theirs <- as.data.frame(arrow::read_feather(file))
    expect_identical(theirs$i, df$i)
    expect_identical(theirs$s, df$s)
    expect_identical(theirs$d, df$d)
    expect_identical(as.character(theirs$f), as.character(df$f))
    expect_identical(theirs$dt, df$dt)
    stream <- arrow_write(
      df,
      NULL,
      format = "stream",
      compression = compression
    )
    expect_identical(as.data.frame(arrow::read_ipc_stream(stream))$s, df$s)
  }
})

test_that("arrow_read() reads what arrow writes, at every compression", {
  skip_if_not_installed("arrow")
  skip_if_not(
    arrow::codec_is_available("zstd") && arrow::codec_is_available("lz4_frame"),
    "arrow was built without its codecs"
  )
  df <- basic_df()
  for (compression in c("uncompressed", "lz4", "zstd")) {
    path <- withr::local_tempfile(fileext = ".arrow")
    arrow::write_feather(df, path, compression = compression)
    expect_identical(without_metadata(arrow_read(path)), df, info = compression)
  }
})

test_that("nanoarrow reads what arrow_write() writes as a stream", {
  skip_if_not_installed("nanoarrow")
  df <- data.frame(x = c(1.5, NA), s = c("a", NA))
  stream <- nanoarrow::read_nanoarrow(arrow_write(df, NULL, format = "stream"))
  expect_identical(as.data.frame(stream), df)
})
