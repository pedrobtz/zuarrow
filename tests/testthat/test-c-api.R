# The public C API (design section 14.1): zuarrow_open_stream() and its
# options, the error stream, zuarrow_error_kind() and the exact parsers,
# reached through src/zar_api_r.c. The oracle is arrow_read(): the C API is
# its reader, so the same file gives the same values or the same class.

test_that("every input reads through the C API as arrow_read() reads it", {
  files <- api_files()
  expect_gt(length(files), 20)
  for (path in files) {
    expect_identical(api_outcome(path), read_outcome(path), info = path)
  }
})

test_that("the oracle tells outcomes apart", {
  # read_outcome() and api_outcome() are compared above; neither may
  # collapse a data frame and an error into one value.
  expect_s3_class(api_outcome(test_data("basic.arrows")), "data.frame")
  expect_identical(
    api_outcome(test_data("crash-node-length.arrow")),
    read_outcome(test_data("crash-node-length.arrow"))
  )
  expect_type(read_outcome(test_data("crash-node-length.arrow")), "character")
})

test_that("compressed bodies need the codec table", {
  df <- data.frame(
    x = rep(1:50, 40),
    s = rep(c("a", "bb", NA), length.out = 2000)
  )
  for (codec in c("lz4", "zstd")) {
    for (format in c("file", "stream")) {
      path <- withr::local_tempfile(fileext = ".arrow")
      arrow_write(df, path, format = format, compression = codec)
      info <- paste(codec, format)
      expect_identical(api_outcome(path), arrow_read(path), info = info)
      expect_identical(api_outcome(path), df, info = info)
      opened <- api_open(path, codecs = "none")
      expect_identical(opened$code, 0L, info = info)
      expect_error(arrow_to_r(opened$stream), class = "zuarrow_codec_error")
      expect_identical(
        .Call(zar_c_api_kind, opened$stream),
        "codec",
        info = info
      )
    }
  }
  # Without compression no table is needed.
  expect_identical(
    api_outcome(test_data("basic.arrow"), codecs = "none"),
    arrow_read(test_data("basic.arrow"))
  )
})

test_that("a codec table of another ABI or too short is refused", {
  for (codecs in c("bad-abi", "short")) {
    opened <- api_open(test_data("basic.arrow"), codecs = codecs)
    expect_false(opened$code == 0L)
    expect_identical(opened$kind, "codec")
    expect_match(opened$message, "codec table")
  }
})

test_that("columns are selected by name and by position, in order", {
  path <- test_data("basic.arrows")
  names <- names(arrow_read(path))
  expect_gte(length(names), 3L)
  pick <- names[c(3L, 1L, 3L)]
  expect_identical(
    api_outcome(path, columns = pick),
    arrow_read(path, columns = pick)
  )
  expect_identical(
    api_outcome(path, indices = c(2L, 0L)),
    arrow_read(path, columns = c(3L, 1L))
  )
  expect_identical(
    api_outcome(path, columns = character()),
    arrow_read(path, columns = character())
  )
  # The same through the file framing.
  expect_identical(
    api_outcome(test_data("basic.arrow"), columns = rev(names)),
    arrow_read(test_data("basic.arrow"), columns = rev(names))
  )
})

test_that("a name matches the first column of that name, as arrow_read()", {
  df <- data.frame(a = 1:2, b = c("x", "y"), a = 3:4, check.names = FALSE)
  path <- withr::local_tempfile(fileext = ".arrows")
  arrow_write(df, path, format = "stream")
  expect_identical(
    api_outcome(path, columns = c("a", "b")),
    arrow_read(path, columns = c("a", "b"))
  )
  expect_identical(api_outcome(path, columns = "a")[[1]], 1:2)
})

test_that("a missing name, a bad position or both selections are type errors", {
  path <- test_data("basic.arrows")
  n <- length(names(arrow_read(path)))
  cases <- list(
    list(columns = "no such column"),
    list(columns = NA_character_),
    list(indices = n),
    list(indices = -1),
    list(columns = names(arrow_read(path))[[1]], indices = 0)
  )
  for (case in cases) {
    opened <- do.call(api_open, c(list(path), case))
    expect_false(opened$code == 0L)
    expect_identical(opened$kind, "type", info = deparse(case))
    # arrow_read() refuses the same selections with the same class.
  }
  expect_match(
    api_open(path, columns = "nope")$message,
    "no column called 'nope'"
  )
  expect_error(arrow_read(path, columns = "nope"), class = "zuarrow_type_error")
  expect_error(arrow_read(path, columns = n + 1), class = "zuarrow_type_error")
  # The last valid position reads.
  expect_identical(
    api_outcome(path, indices = n - 1L),
    arrow_read(path, columns = n)
  )
})

test_that("a failed open leaves a stream that repeats its failure", {
  missing <- file.path(tempdir(), "no-such-file.arrows")
  opened <- api_open(missing)
  expect_false(opened$code == 0L)
  expect_identical(opened$kind, "io")
  expect_match(opened$message, "no-such-file", fixed = TRUE)
  expect_identical(opened$schema_code, opened$code)
  expect_identical(opened$next_code, opened$code)
  expect_identical(opened$next_message, opened$message)
  expect_null(opened$stream)
  expect_error(arrow_read(missing), class = "zuarrow_io_error")

  bad <- api_open(test_data("crash-node-length.arrow"))
  if (bad$code != 0L) {
    expect_identical(bad$schema_code, bad$code)
    expect_identical(bad$next_code, bad$code)
    expect_identical(
      api_class(bad$kind),
      read_outcome(test_data("crash-node-length.arrow"))
    )
  }
  expect_identical(api_open(NULL)$kind, "type")
})

test_that("a stream that fails after opening stays failed and names its kind", {
  # Two batches, the second cut short: the first reads, the second fails.
  bytes <- readBin(test_data("two-batches.arrows"), "raw", 1e6)
  path <- withr::local_tempfile(fileext = ".arrows")
  writeBin(bytes[seq_len(length(bytes) - 20L)], path)
  opened <- api_open(path)
  expect_identical(opened$code, 0L)
  expect_null(.Call(zar_c_api_kind, opened$stream))
  expect_s3_class(arrow_next(opened$stream), "data.frame")
  expect_error(arrow_next(opened$stream), class = "zuarrow_format_error")
  expect_identical(.Call(zar_c_api_kind, opened$stream), "format")
  expect_error(arrow_next(opened$stream), class = "zuarrow_format_error")
  expect_error(arrow_read(path), class = "zuarrow_format_error")
})

test_that("NULL options and zuarrow_options_init() read as arrow_read()", {
  path <- test_data("basic.arrows")
  expect_identical(
    api_outcome(path, limits = NULL, codecs = "none"),
    arrow_read(path)
  )
  # zuarrow_options_init()'s limits are arrow_limits()'s defaults: the
  # deepest schema they allow and one level more.
  expect_identical(
    api_outcome(
      test_data("crash-verifier-deep.arrows"),
      limits = NULL,
      codecs = "none"
    ),
    read_outcome(test_data("crash-verifier-deep.arrows"))
  )
})

test_that("options with a short struct_size are refused", {
  path <- test_data("basic.arrows")
  # ZUARROW_OPTIONS_REQUIRED_SIZE is every field of version 1, 80 bytes on
  # a 64-bit platform: one byte less is refused, the exact size reads.
  for (size in c(0L, 4L, 79L)) {
    opened <- api_open(path, struct_size = size)
    expect_false(opened$code == 0L)
    expect_identical(opened$kind, "type", info = as.character(size))
  }
  if (.Machine$sizeof.pointer == 8L) {
    expect_identical(api_open(path, struct_size = 80L)$code, 0L)
  }
  # A larger struct, as a later header would pass, reads.
  expect_identical(api_open(path, struct_size = 4096L)$code, 0L)
})

test_that("a limit that is negative or NaN is a type error", {
  path <- test_data("basic.arrows")
  base <- as.double(unlist(arrow_limits()))
  for (k in seq_along(base)) {
    for (bad in c(-1, NaN)) {
      if (k == 2L && is.nan(bad)) {
        next
      } # max_depth is an int32_t
      limits <- arrow_limits()
      limits[[k]] <- bad
      opened <- api_open(path, limits = limits)
      expect_identical(opened$kind, "type", info = paste(k, bad))
    }
  }
})

test_that("each limit binds at its value through the C API", {
  path <- test_data("basic.arrows")
  size <- file.size(path)
  rows <- nrow(arrow_read(path))
  for (delta in -1:1) {
    expect_identical(
      api_outcome(path, limits = arrow_limits(max_bytes = size + delta)),
      read_outcome(path, limits = arrow_limits(max_bytes = size + delta)),
      info = delta
    )
    expect_identical(
      api_outcome(path, limits = arrow_limits(max_batch_rows = rows + delta)),
      read_outcome(path, limits = arrow_limits(max_batch_rows = rows + delta)),
      info = delta
    )
  }
  expect_identical(
    api_outcome(path, limits = arrow_limits(max_bytes = size - 1)),
    "zuarrow_limit_error"
  )
  expect_s3_class(
    api_outcome(path, limits = arrow_limits(max_bytes = size)),
    "data.frame"
  )
  for (depth in 0:2) {
    expect_identical(
      api_outcome(path, limits = arrow_limits(max_depth = depth)),
      read_outcome(path, limits = arrow_limits(max_depth = depth)),
      info = depth
    )
  }
  for (message in c(8, 64, 1e6)) {
    expect_identical(
      api_outcome(path, limits = arrow_limits(max_message = message)),
      read_outcome(path, limits = arrow_limits(max_message = message)),
      info = message
    )
  }
})

test_that("the exact parsers are the ones arrow_array() reads text with", {
  int <- api_parse(
    "int64",
    c(
      "0",
      "-1",
      "9223372036854775807",
      "-9223372036854775808",
      "9223372036854775808",
      "+1",
      "01",
      "-0",
      "1x",
      ""
    )
  )
  expect_identical(int$code[1:4], rep(0L, 4))
  expect_identical(
    int$value[1:4],
    c("0", "-1", "9223372036854775807", "-9223372036854775808")
  )
  expect_true(all(int$code[5:8] != 0L & int$code[5:8] != int$code[9]))
  expect_identical(int$code[9], int$code[10])
  uint <- api_parse(
    "uint64",
    c("18446744073709551615", "18446744073709551616", "-1")
  )
  expect_identical(uint$value[[1]], "18446744073709551615")
  expect_true(all(uint$code[2:3] != 0L))
  date <- api_parse(
    "date",
    c("1970-01-01", "2026-11-27", "1969-12-31", "2026-02-29")
  )
  expect_identical(date$value[1:3], c("0", "20784", "-1"))
  expect_identical(
    as.numeric(date$value[[2]]),
    as.numeric(as.Date("2026-11-27"))
  )
  expect_false(date$code[[4]] == 0L)
  inst <- api_parse(
    "instant",
    c("1970-01-01T00:00:01.000001Z", "1970-01-01T00:00:01Z"),
    6L,
    TRUE
  )
  expect_identical(inst$value[[1]], "1000001")
  expect_false(inst$code[[2]] == 0L)
  # Ten fraction digits parse in zar_parse.c, but no unit has them, and
  # 19 would overflow its scale: both are refused.
  expect_false(
    api_parse("instant", "1970-01-01T00:00:00.0000000001Z", 10L, TRUE)$code ==
      0L
  )
  expect_false(api_parse("time", "00:00:00.0000000001", 10L)$code == 0L)
  time <- api_parse("time", c("23:59:59.999", "24:00:00.000"), 3L)
  expect_identical(time$value[[1]], "86399999")
  expect_false(time$code[[2]] == 0L)
  dec <- api_parse(
    "decimal",
    c("123.45", "-0.01", "123.4", "1234.56"),
    c(128L, 5L, 2L)
  )
  expect_identical(dec$value[1:2], c("12345", "-1"))
  expect_true(all(dec$code[3:4] != 0L))

  # The same text through arrow_array(): the same verdicts.
  x <- c("1", "01", "+1")
  structure_ok <- vapply(
    x,
    function(v) {
      tryCatch(
        {
          arrow_array(structure(v, arrow_type = "l"))
          TRUE
        },
        zuarrow_error = function(e) FALSE
      )
    },
    logical(1)
  )
  expect_identical(unname(structure_ok), api_parse("int64", x)$code == 0L)
})

test_that("zuarrow_utf8_invalid_at() agrees with validUTF8()", {
  # No NUL, which an R string cannot hold; a NUL is valid UTF-8 to both.
  withr::local_seed(251)
  cases <- c(
    list(
      charToRaw("caf\u00e9"),
      as.raw(c(0xc0, 0x80)),
      as.raw(c(0xed, 0xa0, 0x80))
    ),
    replicate(
      500,
      as.raw(sample(1:255, sample(0:12, 1), replace = TRUE)),
      FALSE
    )
  )
  for (bytes in cases) {
    at <- .Call(zar_c_api_utf8, bytes)
    valid <- validUTF8(rawToChar(bytes))
    expect_identical(at < 0, valid, info = paste(bytes, collapse = " "))
    if (!valid) {
      # Everything before the offset is valid; the offset is where it stops.
      expect_true(validUTF8(rawToChar(bytes[seq_len(at)])))
      expect_lt(at, length(bytes))
    }
  }
  expect_identical(.Call(zar_c_api_utf8, as.raw(c(0x61, 0xc0, 0x80))), 1)
})
