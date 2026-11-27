test_that("the header and the archive agree on the ABI", {
  expect_identical(abi(), c(1L, 1L))
})

test_that("the builders make every column family a reader needs", {
  got <- stream_columns(build_stream())
  expect_identical(got$formats, expected_formats)
  expect_identical(got$batches, c(3, 1))
  expect_identical(got$columns, expected_columns())
})

test_that("zuarrow reads the built stream as the values it was built from", {
  skip_without_zuarrow()
  # zuarrow validates a foreign stream fully before converting it.
  expect_identical(
    zuarrow::arrow_to_r(build_stream()),
    as_r(expected_columns())
  )
})

test_that("IPC files read through zuarrow_open_stream()", {
  for (name in c("types.arrows", "types.arrow", "types-zstd.arrow")) {
    opened <- read_ipc(extdata(name))
    expect_identical(opened$code, 0L, info = name)
    got <- stream_columns(opened$stream)
    expect_identical(got$formats, expected_formats, info = name)
    expect_identical(got$columns, expected_columns(), info = name)
  }
})

test_that("its values equal arrow_read()'s for the same file", {
  skip_without_zuarrow()
  for (name in c("types.arrows", "types.arrow", "types-zstd.arrow")) {
    path <- extdata(name)
    expect_identical(
      zuarrow::arrow_to_r(read_ipc(path)$stream),
      zuarrow::arrow_read(path),
      info = name
    )
    expect_identical(
      zuarrow::arrow_read(path),
      as_r(expected_columns()),
      info = name
    )
  }
})

test_that("columns are selected by name, in the order given", {
  got <- stream_columns(
    read_ipc(extdata("types.arrow"), columns = c("u", "b"))$stream
  )
  expect_identical(got$columns, expected_columns()[c("u", "b")])
  missing <- read_ipc(extdata("types.arrow"), columns = "nope")
  expect_false(missing$code == 0L)
  expect_identical(missing$kind, "type")
  expect_match(missing$message, "nope")
})

test_that("failures come back as a code, a kind and a message", {
  # No codec table: a compressed body is a codec error at its batch.
  opened <- read_ipc(extdata("repeat-zstd.arrow"))
  expect_identical(opened$code, 0L)
  expect_error(stream_columns(opened$stream), "compressed")
  absent <- read_ipc(file.path(tempdir(), "absent.arrows"))
  expect_identical(absent$kind, "io")
  expect_null(absent$stream)
  path <- extdata("types.arrows")
  limited <- read_ipc(path, max_bytes = file.size(path) - 1)
  expect_identical(limited$kind, "limit")
  expect_identical(read_ipc(path, max_bytes = file.size(path))$code, 0L)
  bad <- tempfile(fileext = ".arrows")
  writeBin(as.raw(c(1:20)), bad)
  expect_identical(read_ipc(bad)$kind, "format")
})

test_that("the exact parsers link and keep their rules", {
  expect_identical(
    parse_int64(c("1", "-9", "+1", "01", "x"))$code,
    c(0L, 0L, 2L, 2L, 1L)
  )
  expect_identical(parse_int64("-42")$value, -42)
  expect_identical(parse_date("2026-11-27")$value, 20784)
  expect_identical(parse_date("2026-02-30")$code, 1L)
})
