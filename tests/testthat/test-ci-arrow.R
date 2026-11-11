# libarrow as an oracle through the arrow R package (design section 9).
# arrow is not a dependency: this file is left out of the package tarball
# (.Rbuildignore) and runs from the source tree, in CI by oracles.yaml.

# From test-oracle-golden.R.
test_that("libarrow decodes the golden files to the same values", {
  skip_without_arrow_codecs()
  skip_without_oracle("nanoarrow")
  # Cases libarrow itself cannot read, as "version case". None today; a
  # case added here is skipped, and one that reads again fails.
  unreadable <- character()
  versions <- c(
    "0.14.1",
    "0.17.1",
    "1.0.0-littleendian",
    "2.0.0-compression",
    "4.0.0-shareddict",
    "cpp-21.0.0"
  )
  for (version in versions) {
    cases <- golden_cases(version)
    for (case in names(cases)) {
      if (no_r_form(case)) {
        next
      }
      label <- paste(version, case)
      path <- paste0(cases[[case]], ".arrow_file")
      table <- tryCatch(
        arrow::read_ipc_file(path, as_data_frame = FALSE),
        error = function(e) NULL
      )
      if (label %in% unreadable) {
        expect_null(table, info = label)
        next
      }
      if (is.null(table)) {
        fail(paste("libarrow cannot read", label))
        next
      }
      theirs <- arrow_to_r(
        nanoarrow::as_nanoarrow_array_stream(table),
        lossy = "character"
      )
      expect_identical(read_golden(path), theirs, info = label)
    }
  }
})

# From test-read.R.
test_that("arrow reads what arrow wrote, the same way", {
  # A minimal arrow build has no zstd: the portability gap D2 removes.
  skip_without_arrow_codecs("zstd")
  path <- test_data("basic-zstd.arrow")
  ours <- without_metadata(arrow_read(path))
  theirs <- as.data.frame(arrow::read_ipc_file(path))
  expect_identical(ours, theirs)
})

# From test-write.R.
# Oracle 4 (design section 9): arrow reads what zuarrow writes, at every
# option, and zuarrow reads what arrow writes.
test_that("arrow reads what arrow_write() writes", {
  skip_without_arrow_codecs()
  df <- basic_df()
  for (compression in c("none", "lz4", "zstd")) {
    file <- arrow_write(df, NULL, compression = compression)
    expect_identical(
      as.data.frame(arrow::read_ipc_file(file)),
      df,
      info = compression
    )
    stream <- arrow_write(
      df,
      NULL,
      format = "stream",
      compression = compression
    )
    expect_identical(
      as.data.frame(arrow::read_ipc_stream(stream)),
      df,
      info = compression
    )
  }
})

# From test-write.R.
test_that("arrow_read() reads what arrow writes, at every compression", {
  skip_without_arrow_codecs()
  df <- basic_df()
  for (compression in c("uncompressed", "lz4", "zstd")) {
    path <- withr::local_tempfile(fileext = ".arrow")
    arrow::write_ipc_file(df, path, compression = compression)
    expect_identical(without_metadata(arrow_read(path)), df, info = compression)
  }
})

test_that("libarrow reads a zero-row factor's levels from zuarrow (#212)", {
  skip_without_oracle("arrow")
  f <- factor(character(), levels = c("u", "v"))
  df <- data.frame(f = f, n = integer())
  for (format in c("file", "stream")) {
    path <- withr::local_tempfile()
    arrow_write(df, path, format = format)
    table <- if (format == "file") {
      arrow::read_ipc_file(path)
    } else {
      arrow::read_ipc_stream(path)
    }
    expect_identical(levels(table$f), c("u", "v"), info = format)
    expect_identical(nrow(table), 0L, info = format)
  }
})

# From test-registry.R (#189, #204).
test_that("arrow_stream() exported to arrow outlives every R reference", {
  skip_without_oracle("arrow")
  skip_without_oracle("nanoarrow")
  local_registration(
    "g",
    from = function(x) arrow_array(as.double(unclass(x))),
    class = "fake_dbl"
  )
  n <- 5000L
  expected <- data.frame(id = seq_len(n), v = as.double(seq_len(n)) * 10)
  for (batch in c(n, 1000L)) {
    reader <- local({
      df <- expected
      df$v <- structure(df$v, class = "fake_dbl")
      stream <- arrow_stream(df, batch = batch)
      arrow::as_record_batch_reader(
        nanoarrow::as_nanoarrow_array_stream(stream)
      )
    })
    heap_churn()
    table <- reader$read_table()
    rm(reader)
    heap_churn()
    expect_identical(as.data.frame(table), expected, info = batch)
  }
})

# From test-write.R (#206).
test_that("arrow reads a batch whose columns outrun it, at its length", {
  skip_without_oracle("arrow")
  skip_without_oracle("nanoarrow")
  read <- list(file = arrow::read_ipc_file, stream = arrow::read_ipc_stream)
  df <- data.frame(x = 1:5, y = letters[1:5])
  # A zero-offset slice of a libarrow struct: children of 5, length 3.
  sliced <- nanoarrow::as_nanoarrow_array(
    arrow::StructArray$create(df)$Slice(0, 3)
  )
  schema <- test_schema(zspec(
    "+s",
    children = list(zspec("i", "x"), zspec("n", "z"))
  ))
  raw_batch <- test_array(
    schema,
    3,
    list(NULL),
    children = list(
      test_array_spec(5, list(NULL, le_int(1:5, 4L))),
      test_array_spec(5, list(), null_count = 5)
    )
  )
  for (format in names(read)) {
    out <- as.data.frame(read[[format]](arrow_write(
      sliced,
      NULL,
      format = format
    )))
    expect_identical(out, df[1:3, ], info = format)
    out <- read[[format]](arrow_write(raw_batch, NULL, format = format))
    expect_identical(nrow(out), 3L, info = format)
    expect_identical(out$x, 1:3, info = format)
  }
})

# From test-read-rules.R (#208).
test_that("zuarrow and arrow agree on a batch length off its columns'", {
  skip_without_oracle("arrow")
  df <- data.frame(x = 1:4, y = c("a", "b", "c", "d"))
  bytes <- arrow::write_to_raw(df, format = "stream")
  m <- ipc_messages(bytes)
  batch <- Filter(function(m) m$type == 3, m)[[1]]
  for (length in 3:5) {
    patched <- ipc_set_batch_length(bytes, batch, length)
    arrow_reads <- tryCatch(
      {
        as.data.frame(arrow::read_ipc_stream(patched))
        TRUE
      },
      error = function(e) FALSE
    )
    expect_identical(arrow_reads, length == 4, info = paste(length))
    if (arrow_reads) {
      expect_identical(arrow_read(patched)$x, df$x, info = paste(length))
    } else {
      expect_error(arrow_read(patched), class = "zuarrow_format_error")
    }
  }
})
