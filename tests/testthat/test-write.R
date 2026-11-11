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

test_that("a write that fails to open or write is an io error", {
  missing <- file.path(withr::local_tempdir(), "no", "dir.arrow")
  expect_error(arrow_write(basic_df(), missing), class = "zuarrow_io_error")
  # A connection that cannot be opened for writing.
  con <- file(missing)
  withr::defer(try(close(con), silent = TRUE))
  expect_error(arrow_write(basic_df(), con), class = "zuarrow_io_error")
  # A connection already open, but only for reading.
  path <- withr::local_tempfile()
  writeBin(as.raw(1:4), path)
  con <- file(path, "rb")
  withr::defer(close(con))
  expect_error(arrow_write(basic_df(), con), class = "zuarrow_io_error")
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
  # A stream built over the array moves it out and leaves the handle
  # released; the stream itself is not used.
  .Call(zar_c_stream_from_arrays, arrow_schema(array), list(array))
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
  df <- data.frame(x = sample.int(.Machine$integer.max, 2000))
  values <- writeBin(df$x, raw(), endian = "little")
  for (compression in c("lz4", "zstd")) {
    out <- arrow_write(df, NULL, compression = compression)
    expect_identical(without_metadata(arrow_read(out)), df)
    # The -1 length prefix, then the values as they are.
    expect_length(
      bytes_at(out, c(as.raw(rep(0xff, 8)), values)),
      1L
    )
  }
})

test_that("compression levels are passed to the codec", {
  df <- data.frame(s = rep(c("abc", "defg"), 500))
  fast <- arrow_write(df, NULL, compression = "zstd", level = 1)
  best <- arrow_write(df, NULL, compression = "zstd", level = 19)
  expect_identical(without_metadata(arrow_read(fast)), df)
  expect_identical(without_metadata(arrow_read(best)), df)
  expect_lt(length(best), length(fast))
})

test_that("a level outside the codec's range is a codec error", {
  df <- data.frame(s = rep("abc", 100))
  expect_error(
    arrow_write(df, NULL, compression = "zstd", level = 1000L),
    class = "zuarrow_codec_error"
  )
  expect_error(
    arrow_write(df, NULL, compression = "lz4", level = 99L),
    class = "zuarrow_codec_error"
  )
  # The codec's own refusal, past the R check, is a codec error too.
  array <- arrow_array(df)
  out <- .Call(
    zuarrow:::zar_c_write,
    list(array),
    arrow_schema(array),
    list(TRUE, 2L, 1000L)
  )
  expect_s3_class(out, "zar_failure")
  expect_identical(out$kind, "codec")
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
})

test_that("compressed output is the same bytes, pinned per codec version", {
  # The compressed bytes are the codec's, so their hashes are pinned only
  # for the lz4 and zstd versions zukomp bundled when they were taken. Under
  # any other version the bytes must still repeat and read back.
  df <- determinism_df()
  vendored <- zukomp::komp_info()$vendored
  codec_version <- function(source) vendored$version[vendored$source == source]
  pinned <- list(
    lz4 = list(version = "1.10.0", md5 = "91190b836a4a6e1f48a23e15a3461770"),
    zstd = list(version = "1.5.7", md5 = "67e26b55dd346508c43c6125a7628f6a")
  )
  for (codec in names(pinned)) {
    bytes <- arrow_write(df, NULL, compression = codec, batch = 3)
    expect_identical(
      arrow_write(df, NULL, compression = codec, batch = 3),
      bytes,
      info = codec
    )
    expect_identical(arrow_read(bytes), df, info = codec)
    if (identical(codec_version(codec), pinned[[codec]]$version)) {
      expect_identical(md5_of(bytes), pinned[[codec]]$md5, info = codec)
    }
  }
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
  expect_error(
    arrow_write(basic_df(), NULL, compression = "gzip"),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_write(basic_df(), NULL, format = "feather"),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_write(basic_df(), file.path(tempfile(), "no", "dir.arrow")),
    class = "zuarrow_io_error"
  )
})

test_that("only a struct array or stream can be written", {
  expect_error(
    arrow_write(arrow_array(1:3), NULL),
    class = "zuarrow_type_error"
  )
})

test_that("a dictionary of nested values is written with their children", {
  # #140: the schema kept the value type but dropped its children.
  spec <- zspec("i", "x")
  spec$dictionary <- zspec("+s", children = list(zspec("i", "a")))
  array <- test_array(
    test_schema(zspec("+s", children = list(spec))),
    3,
    list(NULL),
    children = list(test_array_spec(
      3,
      list(NULL, le_int(c(1, 0, 1), 4L)),
      dictionary = test_array_spec(
        2,
        list(NULL),
        children = list(test_array_spec(2, list(NULL, le_int(c(5, 6), 4L))))
      )
    ))
  )
  for (format in c("stream", "file")) {
    bytes <- arrow_write(array, NULL, format = format)
    expect_identical(
      format(arrow_schema(arrow_read(bytes, lazy = TRUE))),
      "struct<x: dictionary(int32)<struct<a: int32>>>"
    )
    expect_identical(arrow_read(bytes)$x, data.frame(a = c(6L, 5L, 6L)))
  }
})

test_that("a sliced batch is written as the values it holds", {
  dict_field <- zspec("i", "f")
  dict_field$dictionary <- zspec("u")
  schema <- test_schema(zspec(
    "+s",
    children = list(
      zspec("i", "x"),
      zspec("u", "s"),
      zspec("b", "b"),
      zspec("+l", "l", children = list(zspec("i", "item"))),
      dict_field
    )
  ))
  # The struct starts at row 1 and each child but `s` has its own offset.
  batch <- test_array(
    schema,
    2,
    list(NULL),
    offset = 1,
    children = list(
      test_array_spec(3, list(NULL, le_int(c(10, 20, 30, 40), 4L)), offset = 1),
      test_array_spec(
        3,
        list(NULL, le_int(c(0, 1, 3, 6), 4L), charToRaw("abbccc"))
      ),
      # Bits 3 and 4 hold TRUE and FALSE; bit 4 is null.
      test_array_spec(
        3,
        list(as.raw(0xef), as.raw(0x4d)),
        null_count = 1,
        offset = 2
      ),
      test_array_spec(
        3,
        list(NULL, le_int(c(0, 0, 1, 1, 3), 4L)),
        offset = 1,
        children = list(test_array_spec(
          3,
          list(NULL, le_int(c(6, 7, 8, 9), 4L)),
          offset = 1
        ))
      ),
      test_array_spec(
        3,
        list(NULL, le_int(c(0, 0, 1, 0), 4L)),
        offset = 1,
        dictionary = test_array_spec(
          2,
          list(NULL, le_int(c(0, 1, 2, 3), 4L), charToRaw("zab")),
          offset = 1
        )
      )
    )
  )
  for (format in c("file", "stream")) {
    out <- arrow_read(arrow_write(batch, NULL, format = format))
    expect_identical(out$x, c(30L, 40L), info = format)
    expect_identical(out$s, c("bb", "ccc"), info = format)
    expect_identical(out$b, c(TRUE, NA), info = format)
    expect_identical(out$l, list(integer(), c(8L, 9L)), info = format)
    expect_identical(
      out$f,
      factor(c("b", "a"), levels = c("a", "b")),
      info = format
    )
  }
})

test_that("a sliced union is written as the values it holds", {
  schema <- test_schema(zspec(
    "+s",
    children = list(zspec(
      "+us:0,1",
      "u",
      children = list(zspec("i", "a"), zspec("u", "b"))
    ))
  ))
  sliced <- test_array(
    schema,
    2,
    list(NULL),
    offset = 1,
    children = list(test_array_spec(
      3,
      list(as.raw(c(0, 0, 1))),
      children = list(
        test_array_spec(3, list(NULL, le_int(c(1, 2, 3), 4L))),
        test_array_spec(
          3,
          list(NULL, le_int(c(0, 1, 2, 3), 4L), charToRaw("xyz"))
        )
      )
    ))
  )
  expected <- test_array(
    schema,
    2,
    list(NULL),
    children = list(test_array_spec(
      2,
      list(as.raw(c(0, 1))),
      children = list(
        test_array_spec(2, list(NULL, le_int(c(2, 3), 4L))),
        test_array_spec(2, list(NULL, le_int(c(0, 1, 2), 4L), charToRaw("yz")))
      )
    ))
  )
  # A union has no R form, so the bytes are compared with the unsliced
  # array's.
  expect_identical(arrow_write(sliced, NULL), arrow_write(expected, NULL))

  # A dense union keeps its children whole: its offsets point into them.
  schema <- test_schema(zspec(
    "+s",
    children = list(zspec(
      "+ud:0,1",
      "u",
      children = list(zspec("i", "a"), zspec("u", "b"))
    ))
  ))
  dense <- function(offset, types, offsets) {
    test_array(
      schema,
      2,
      list(NULL),
      offset = offset,
      children = list(test_array_spec(
        length(types),
        list(as.raw(types), le_int(offsets, 4L)),
        children = list(
          test_array_spec(2, list(NULL, le_int(c(1, 2), 4L))),
          test_array_spec(1, list(NULL, le_int(c(0, 1), 4L), charToRaw("x")))
        )
      ))
    )
  }
  expect_identical(
    arrow_write(dense(1, c(0, 0, 1), c(0, 1, 0)), NULL),
    arrow_write(dense(0, c(0, 1), c(1, 0)), NULL)
  )
})

test_that("a sliced run-end encoded column is a type error", {
  schema <- test_schema(zspec(
    "+s",
    children = list(zspec(
      "+r",
      "r",
      children = list(zspec("i", "run_ends"), zspec("i", "values"))
    ))
  ))
  batch <- test_array(
    schema,
    1,
    list(NULL),
    offset = 1,
    children = list(test_array_spec(
      2,
      list(),
      children = list(
        test_array_spec(1, list(NULL, le_int(2, 4L))),
        test_array_spec(1, list(NULL, le_int(5, 4L)))
      )
    ))
  )
  expect_error(arrow_write(batch, NULL), class = "zuarrow_type_error")
})

test_that("a view layout is a type error", {
  for (format in c("vu", "vz")) {
    schema <- test_schema(zspec("+s", children = list(zspec(format, "v"))))
    batch <- test_array(
      schema,
      0,
      list(NULL),
      children = list(test_array_spec(0, list(NULL, raw())))
    )
    expect_error(
      arrow_write(batch, NULL),
      class = "zuarrow_type_error",
      info = format
    )
  }
})

test_that("null rows in a batch are a type error", {
  schema <- test_schema(zspec("+s", children = list(zspec("i", "x"))))
  batch <- test_array(
    schema,
    2,
    list(as.raw(0x01)),
    null_count = 1,
    children = list(test_array_spec(2, list(NULL, le_int(c(1, 2), 4L))))
  )
  expect_error(arrow_write(batch, NULL), class = "zuarrow_type_error")
})

test_that("a malformed batch is a format error", {
  schema <- test_schema(zspec("+s", children = list(zspec("i", "x"))))
  # Three rows, but a field of two.
  batch <- test_array(
    schema,
    3,
    list(NULL),
    children = list(test_array_spec(2, list(NULL, le_int(c(1, 2), 4L))))
  )
  expect_error(arrow_write(batch, NULL), class = "zuarrow_format_error")
})

test_that("bad string offsets are a format error, never written (#150)", {
  frame <- function(offsets, offset = 0) {
    n <- length(offsets) - 1
    test_array(
      test_schema(zspec("+s", children = list(zspec("u", "s")))),
      n - offset,
      list(NULL),
      offset = offset,
      children = list(test_array_spec(
        n,
        list(NULL, le_int(offsets, 4L), charToRaw("abcde"))
      ))
    )
  }
  # Default validation checks only the first and last offsets.
  expect_error(
    arrow_write(frame(c(0, 3, 1, 5)), NULL),
    class = "zuarrow_format_error"
  )
  expect_error(
    arrow_write(frame(c(0, 4000, 5)), NULL),
    class = "zuarrow_format_error"
  )
  # A sliced batch is copied through its offsets.
  expect_error(
    arrow_write(frame(c(0, 3, 1, 4, 5), offset = 1), NULL),
    class = "zuarrow_format_error"
  )
  spec <- zspec("i", "x")
  spec$dictionary <- zspec("u")
  dict <- test_array(
    test_schema(zspec("+s", children = list(spec))),
    2,
    list(NULL),
    children = list(test_array_spec(
      2,
      list(NULL, le_int(c(0, 1), 4L)),
      dictionary = test_array_spec(
        2,
        list(NULL, le_int(c(0, 4000, 5), 4L), charToRaw("abcde"))
      )
    ))
  )
  expect_error(arrow_write(dict, NULL), class = "zuarrow_format_error")
})

test_that("a field with no name is written with an empty name (#201)", {
  spec <- function(x) .Call(zar_c_schema_to_spec, arrow_schema(x))
  unnamed <- data.frame(x = 1:2)
  names(unnamed) <- NA_character_
  nested <- data.frame(id = 1:2)
  nested$pos <- data.frame(x = c(1, 2))
  names(nested$pos) <- NA_character_
  # A list whose item has no name.
  item <- test_array(
    test_schema(zspec(
      "+s",
      children = list(zspec("+l", "l", list(zspec("i", NA_character_))))
    )),
    1,
    list(NULL),
    children = list(test_array_spec(
      1,
      list(NULL, le_int(c(0, 2), 4L)),
      children = list(test_array_spec(2, list(NULL, le_int(1:2, 4L))))
    ))
  )
  for (format in c("file", "stream")) {
    out <- arrow_read(arrow_write(unnamed, NULL, format = format))
    expect_identical(names(out), "")
    expect_identical(out[[1]], 1:2)
    out <- arrow_read(arrow_write(nested, NULL, format = format))
    expect_identical(names(out$pos), "")
    expect_identical(out$pos[[1]], c(1, 2))
    stream <- arrow_read(arrow_write(item, NULL, format = format), lazy = TRUE)
    expect_identical(spec(stream)$children[[1]]$children[[1]]$name, "")
    expect_identical(arrow_to_r(stream)$l, list(1:2))
  }
})

test_that("metadata values that hold a NUL are written whole (#202)", {
  value <- as.raw(c(0x61, 0x00, 0x62))
  df <- data.frame(x = 1:2, e = 3:4)
  attr(df$x, "arrow_field_metadata") <- list(unit = value)
  attr(df$e, "arrow_extension") <- "zuarrow.test"
  attr(df$e, "arrow_extension_metadata") <- as.raw(c(0x00, 0x01))
  for (format in c("file", "stream")) {
    bytes <- arrow_write(df, NULL, format = format, metadata = list(k = value))
    expect_true(length(bytes_at(bytes, value)) > 0L)
    out <- arrow_read(bytes)
    expect_identical(attr(out, "arrow_metadata"), list(k = value))
    expect_identical(attr(out$x, "arrow_field_metadata"), list(unit = value))
    expect_identical(
      attr(out$e, "arrow_extension_metadata"),
      as.raw(c(0x00, 0x01))
    )
  }
})
