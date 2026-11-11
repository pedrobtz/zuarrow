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

# #186: libarrow reads what arrow_write() writes, for every type. A round
# trip through zuarrow alone cannot see a mistake its writer and reader
# share.
test_that("libarrow reads arrow_write() of every golden case as the case", {
  skip_without_arrow_codecs()
  versions <- c(
    "0.14.1",
    "0.17.1",
    "1.0.0-littleendian",
    "2.0.0-compression",
    "4.0.0-shareddict",
    "cpp-21.0.0"
  )
  # The view layouts have no IPC encoding in the vendored encoder.
  unwritable <- c("generated_binary_view", "generated_list_view")
  for (version in versions) {
    cases <- golden_cases(version)
    for (case in names(cases)) {
      path <- paste0(cases[[case]], ".arrow_file")
      label <- paste(version, case)
      write <- function(format, compression) {
        arrow_write(
          arrow_read(path, lazy = TRUE),
          NULL,
          format = format,
          compression = compression
        )
      }
      if (case %in% unwritable) {
        expect_error(write("file", "none"), class = "zuarrow_type_error")
        next
      }
      expected <- arrow::read_ipc_file(path, as_data_frame = FALSE)
      # Some golden values are outside their type (a decimal past its
      # precision, a date64 that is not a whole day); libarrow's full
      # validation refuses those in the original as well.
      valid <- tryCatch(
        {
          expected$ValidateFull()
          TRUE
        },
        error = function(e) FALSE
      )
      expect_libarrow_reads(
        write,
        expected,
        zuarrow_outcome(function() arrow_read(path, lossy = "character")),
        label,
        validate = valid
      )
    }
  }
})

test_that("libarrow reads arrow_write() of its own tables of every type", {
  skip_without_arrow_codecs()
  skip_without_oracle("nanoarrow")
  table <- libarrow_types_table()
  more <- table$Slice(1, 3)
  inputs <- list(
    whole = table,
    sliced = table$Slice(2, 4),
    zero_rows = table$Slice(0, 0),
    batches = arrow::concat_tables(table, more, table)
  )
  for (name in names(inputs)) {
    input <- inputs[[name]]
    source <- function() nanoarrow::as_nanoarrow_array_stream(input)
    expect_libarrow_reads(
      function(format, compression) {
        arrow_write(source(), NULL, format = format, compression = compression)
      },
      input,
      zuarrow_outcome(function() arrow_to_r(source(), lossy = "character")),
      name
    )
  }
})

test_that("libarrow reads a stream whose dictionaries change", {
  skip_without_arrow_codecs()
  skip_without_oracle("nanoarrow")
  one <- arrow::arrow_table(
    f = arrow::DictionaryArray$create(c(0L, 1L), c("a", "b")),
    s = arrow::StructArray$create(data.frame(g = factor(c("p", "q"))))
  )
  two <- arrow::arrow_table(
    f = arrow::DictionaryArray$create(c(1L, 0L, NA), c("c", "d")),
    s = arrow::StructArray$create(data.frame(g = factor(c("r", NA, "r"))))
  )
  input <- arrow::concat_tables(one, two)
  source <- function() nanoarrow::as_nanoarrow_array_stream(input)
  # The file format cannot replace a dictionary.
  expect_libarrow_reads(
    function(format, compression) {
      arrow_write(source(), NULL, format = format, compression = compression)
    },
    input,
    zuarrow_outcome(function() arrow_to_r(source(), lossy = "character")),
    "changing dictionaries",
    formats = "stream"
  )
})

test_that("libarrow reads arrow_write() of R columns as zuarrow exports them", {
  skip_without_arrow_codecs()
  skip_without_oracle("nanoarrow")
  n <- 7L
  when <- as.POSIXct("2024-03-10 01:30:00", tz = "UTC") + 3600 * seq_len(n)
  df <- data.frame(
    int = c(1:3, NA, 5:7),
    # No NaN: libarrow's Equals() holds NaN unequal to itself.
    dbl = c(1.5, NA, -0, Inf, -Inf, 1e300, 7),
    lgl = c(TRUE, NA, FALSE, TRUE, FALSE, NA, TRUE),
    chr = c("a", NA, "", "é", "日本", "f", "g"),
    fct = factor(c("x", "y", NA, "x", "z", "y", "x")),
    date = as.Date("2000-02-28") + c(0:2, NA, 4:6)
  )
  df$utc <- when
  df$new_york <- `attr<-`(when, "tzone", "America/New_York")
  df$no_zone <- `attr<-`(when, "tzone", "")
  df$secs <- as.difftime(c(1:3, NA, 5:7), units = "secs")
  df$weeks <- as.difftime(c(0.5, 1:6), units = "weeks")
  df$raw <- lapply(seq_len(n), function(i) as.raw(seq_len(i - 1L)))
  df$ints <- list(1:2, NULL, integer(), 3L, NA_integer_, 4:6, 7L)
  df$chrs <- list("a", c("b", NA), character(), NULL, "c", "d", "e")
  df$fcts <- lapply(seq_len(n), function(i) {
    factor(c("u", "v")[seq_len(i %% 3L)], levels = c("u", "v"))
  })
  df$nested <- data.frame(
    a = c(1:6, NA),
    b = factor(c("p", "q", "p", NA, "q", "p", "q"))
  )
  df$nested$c <- list(1, c(2, 3), NULL, 4, 5, 6, 7)
  df$nested$inner <- data.frame(z = c(letters[1:6], NA))
  attr(df$int, "arrow_field_metadata") <- c(field_key = "field value")
  attr(df$dbl, "arrow_extension") <- "zuarrow.test"
  attr(df$dbl, "arrow_extension_metadata") <- "extension metadata"
  metadata <- c(schema_key = "schema value", other = "é")
  inputs <- list(
    whole = df,
    zero_rows = df[0, ],
    one_row = df[4, ]
  )
  for (name in names(inputs)) {
    input <- inputs[[name]]
    for (batch in c(3L, 65536L)) {
      expected <- libarrow_import(arrow_stream(input, batch = batch))
      expected$metadata <- as.list(metadata)
      expect_libarrow_reads(
        function(format, compression) {
          arrow_write(
            input,
            NULL,
            format = format,
            compression = compression,
            batch = batch,
            metadata = metadata
          )
        },
        expected,
        zuarrow_outcome(function() {
          arrow_to_r(arrow_stream(input), lossy = "character")
        }),
        paste(name, batch)
      )
    }
  }
})

# The native review's R6: a dictionary inside a dictionary's values. Its
# batch must come first, as the format orders dictionaries by dependency.
test_that("libarrow and zuarrow read a dictionary inside a dictionary's values", {
  skip_without_arrow_codecs()
  skip_without_oracle("nanoarrow")
  inner <- zspec("i", "a")
  inner$dictionary <- zspec("u")
  outer <- zspec("i", "x")
  outer$dictionary <- zspec("+s", children = list(inner))
  schema <- test_schema(zspec("+s", children = list(outer)))
  batch <- function(indices, inner_indices, offsets, data) {
    test_array(
      schema,
      length(indices),
      list(NULL),
      children = list(test_array_spec(
        length(indices),
        list(NULL, le_int(indices, 4L)),
        dictionary = test_array_spec(
          length(inner_indices),
          list(NULL),
          children = list(test_array_spec(
            length(inner_indices),
            list(NULL, le_int(inner_indices, 4L)),
            dictionary = test_array_spec(
              length(offsets) - 1L,
              list(NULL, le_int(offsets, 4L), charToRaw(data))
            )
          ))
        )
      ))
    )
  }
  one <- function() batch(c(0, 1, 1), c(1, 0), c(0, 3, 6), "foobar")
  two <- function() batch(c(1, 0), c(0, 2, 1), c(0, 1, 2, 3), "xyz")
  sources <- list(
    one_batch = list(
      make = function() test_stream(schema, list(one())),
      formats = c("file", "stream")
    ),
    same_dictionaries = list(
      make = function() test_stream(schema, list(one(), one())),
      formats = c("file", "stream")
    ),
    new_dictionaries = list(
      make = function() test_stream(schema, list(one(), two())),
      formats = "stream"
    )
  )
  for (name in names(sources)) {
    make <- sources[[name]]$make
    expect_libarrow_reads(
      function(format, compression) {
        arrow_write(make(), NULL, format = format, compression = compression)
      },
      libarrow_import(make()),
      zuarrow_outcome(function() arrow_to_r(make(), lossy = "character")),
      name,
      formats = sources[[name]]$formats
    )
  }
})
