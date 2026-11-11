# libarrow as the reader of what arrow_write() writes (#186). Like every
# helper-ci-* file, this one is left out of the package tarball.

# The table libarrow reads from IPC bytes.
libarrow_read <- function(bytes, format) {
  if (format == "file") {
    arrow::read_ipc_file(bytes, as_data_frame = FALSE)
  } else {
    arrow::read_ipc_stream(bytes, as_data_frame = FALSE)
  }
}

# The outcome of reading with zuarrow: the data frame without its schema
# metadata, which libarrow checks, or the class of the condition raised.
zuarrow_outcome <- function(f) {
  tryCatch(
    without_metadata(f()),
    zuarrow_error = function(e) class(e)[[1]]
  )
}

# Calls `write(format, compression)` in both framings at each codec, and
# checks libarrow's reading of the bytes against the table `expected`:
# valid at libarrow's full level, unless `validate` is FALSE, and equal
# with metadata. zuarrow's own reading of the bytes must give `reference`,
# a zuarrow_outcome(). `formats` lists the framings that must write; the
# others must be a zuarrow_type_error.
expect_libarrow_reads <- function(
  write,
  expected,
  reference,
  label,
  formats = c("file", "stream"),
  validate = TRUE
) {
  for (format in c("file", "stream")) {
    for (compression in c("none", "lz4", "zstd")) {
      info <- paste(label, format, compression)
      if (!format %in% formats) {
        expect_error(
          write(format, compression),
          class = "zuarrow_type_error",
          info = info
        )
        next
      }
      bytes <- write(format, compression)
      table <- libarrow_read(bytes, format)
      if (validate) {
        valid <- tryCatch(
          {
            table$ValidateFull()
            TRUE
          },
          error = function(e) conditionMessage(e)
        )
        expect_true(isTRUE(valid), info = paste(info, valid))
      }
      expect_true(table$Equals(expected, check_metadata = TRUE), info = info)
      ours <- zuarrow_outcome(function() {
        arrow_read(bytes, lossy = "character")
      })
      expect_identical(ours, reference, info = info)
    }
  }
}

# A libarrow table of the types arrow_types() lists that libarrow builds
# from R values, with nulls, nested dictionaries and schema metadata.
# Unions, intervals and run-end encoding, which arrow builds from no R
# value, come from the golden files.
libarrow_types_table <- function() {
  A <- function(x, type) arrow::Array$create(x, type = type)
  v <- c(1:3, NA, 5:7)
  num <- c(1.25, NA, 2, 3, 4, 5, 6)
  text <- c("a", NA, "ccc", "", "é", "f", "g")
  bytes <- lapply(1:7, function(i) as.raw(seq_len(i)))
  when <- as.POSIXct("2020-01-01", tz = "UTC") + v
  lists <- list(1:2, NULL, integer(), 3L, 4:6, 7L, 8L)
  kv <- function(key, value) data.frame(key = key, value = value)
  maps <- list(
    kv(c("a", "b"), 1:2),
    NULL,
    kv(character(), integer()),
    kv("c", 3L),
    kv("d", NA_integer_),
    kv("e", 5L),
    kv("f", 6L)
  )
  ab <- c("a", "b")
  cols <- list(
    null = A(rep(NA, 7), arrow::null()),
    bool = A(c(TRUE, FALSE, NA, TRUE, TRUE, FALSE, NA), arrow::boolean()),
    i8 = A(v, arrow::int8()),
    i16 = A(v, arrow::int16()),
    i32 = A(v, arrow::int32()),
    i64 = A(v, arrow::int64()),
    u8 = A(v, arrow::uint8()),
    u16 = A(v, arrow::uint16()),
    u32 = A(v, arrow::uint32()),
    u64 = A(v, arrow::uint64()),
    f16 = A(num, arrow::float16()),
    f32 = A(num, arrow::float32()),
    f64 = A(num, arrow::float64()),
    utf8 = A(text, arrow::utf8()),
    large_utf8 = A(text, arrow::large_utf8()),
    binary = A(bytes, arrow::binary()),
    large_binary = A(bytes, arrow::large_binary()),
    fixed_binary = A(
      lapply(1:7, function(i) as.raw(c(i, i, i))),
      arrow::fixed_size_binary(3)
    ),
    date32 = A(as.Date("2020-01-01") + v, arrow::date32()),
    date64 = A(as.Date("2020-01-01") + v, arrow::date64()),
    ts_s = A(when, arrow::timestamp("s", "UTC")),
    ts_ms = A(when, arrow::timestamp("ms", "America/New_York")),
    ts_us = A(when, arrow::timestamp("us", "Asia/Kolkata")),
    ts_ns = A(when, arrow::timestamp("ns")),
    time32_s = A(v, arrow::int32())$cast(arrow::time32("s")),
    time32_ms = A(v, arrow::int32())$cast(arrow::time32("ms")),
    time64_us = A(v, arrow::int64())$cast(arrow::time64("us")),
    time64_ns = A(v, arrow::int64())$cast(arrow::time64("ns")),
    duration_s = A(as.difftime(v, units = "secs"), arrow::duration("s")),
    duration_ms = A(as.difftime(v, units = "secs"), arrow::duration("ms")),
    duration_us = A(as.difftime(v, units = "secs"), arrow::duration("us")),
    duration_ns = A(as.difftime(v, units = "secs"), arrow::duration("ns")),
    decimal32 = A(num, arrow::decimal32(7, 2)),
    decimal64 = A(num, arrow::decimal64(15, 2)),
    decimal128 = A(num, arrow::decimal128(10, 2)),
    decimal256 = A(num, arrow::decimal256(40, 2)),
    struct = arrow::StructArray$create(data.frame(a = v, b = text)),
    list = A(lists, arrow::list_of(arrow::int32())),
    large_list = A(lists, arrow::large_list_of(arrow::int32())),
    fixed_list = A(
      lapply(1:7, function(i) c(i, -i)),
      arrow::fixed_size_list_of(arrow::int32(), 2)
    ),
    map = A(maps, arrow::map_of(arrow::utf8(), arrow::int32())),
    dict = arrow::DictionaryArray$create(
      c(0L, 1L, NA, 2L, 0L, 1L, 2L),
      c("a", "b", "c")
    ),
    dict_double = arrow::DictionaryArray$create(
      c(1L, 0L, NA, 1L, 0L, 1L, 0L),
      A(c(10, 20), arrow::float64())
    ),
    list_dict = arrow::Array$create(list(
      factor(ab),
      NULL,
      factor("b", levels = ab),
      factor(character(), levels = ab),
      factor("a", levels = ab),
      factor("b", levels = ab),
      factor(c("a", "a"), levels = ab)
    )),
    struct_dict = arrow::StructArray$create(data.frame(
      f = factor(c("x", "y", NA, "x", "y", "x", "y")),
      n = v
    ))
  )
  table <- do.call(arrow::arrow_table, cols)
  table$metadata <- list(schema_key = "schema value")
  table
}

# libarrow's import of a zuarrow stream through the C Data Interface: what
# zuarrow holds before any IPC encoding.
libarrow_import <- function(stream) {
  reader <- arrow::as_record_batch_reader(
    nanoarrow::as_nanoarrow_array_stream(stream)
  )
  reader$read_table()
}
