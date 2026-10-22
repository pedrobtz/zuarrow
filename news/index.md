# Changelog

## zuarrow 0.0.0.9000

- Initial CRAN submission.

### Handles

- [`arrow_schema()`](https://pedrobtz.github.io/zuarrow/reference/arrow_schema.md)
  makes a schema handle from an Arrow format string, from an R object,
  or from any schema, array or stream handle, and
  [`format()`](https://rdrr.io/r/base/format.html) and
  [`print()`](https://rdrr.io/r/base/print.html) show Arrow’s type
  notation.
- Handles share the ‘nanoarrow’ package’s layout and inherit from its
  classes, so handles cross between the two packages without conversion.
- [`arrow_validate()`](https://pedrobtz.github.io/zuarrow/reference/arrow_validate.md)
  runs the bundled ‘nanoarrow’ C library’s validation at `"minimal"`,
  `"default"` or `"full"`; `"full"` also checks that every string is
  valid UTF-8.
- [`arrow_equal()`](https://pedrobtz.github.io/zuarrow/reference/arrow_equal.md)
  compares two schemas, arrays or streams, and says why they differ.
- [`arrow_metadata()`](https://pedrobtz.github.io/zuarrow/reference/arrow_metadata.md)
  and `arrow_metadata<-` read and write schema metadata, keeping binary
  values as raw vectors.
- [`zuarrow_info()`](https://pedrobtz.github.io/zuarrow/reference/zuarrow_info.md)
  reports the versions zuarrow is built from.
- Every error inherits from `zuarrow_error`, and the lossy warning from
  `zuarrow_warning`.

### Converting to and from R

- [`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
  converts an array to an R vector and a stream or struct array to a
  data frame;
  [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) and
  [`as.vector()`](https://rdrr.io/r/base/vector.html) do the same, and
  [`arrow_next()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
  reads one batch.
- A conversion is exact or it fails: `lossy = "error"`, the default
  everywhere, raises `zuarrow_lossy_error` naming the column, the row
  and the package that would read it exactly. `lossy = "character"`
  gives the values’ exact text, `"warn"` and `"allow"` the nearest R
  type.
- `to` names the R type a column must become.
- `copy = FALSE` defers string columns in
  [`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md),
  [`arrow_next()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md),
  [`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md)
  and [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html).
  Each becomes a character vector that creates its R strings on first
  use, which is most of the cost of a string column. Values are checked
  during the conversion either way, so the errors are the same. The
  default, `copy = TRUE`, creates every value at once.
- [`arrow_array()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
  and
  [`arrow_stream()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
  build arrays and streams from R vectors and data frames, checking
  every value against a given schema. The exact text that
  `lossy = "character"` returns is written back as the type its
  `arrow_type` attribute names.
- [`arrow_types()`](https://pedrobtz.github.io/zuarrow/reference/arrow_types.md)
  lists the built-in type table.

### Nested types, dictionaries and the registry

- Structs convert to nested data frames, lists of every kind to list
  columns, fixed-size lists to list columns or, with
  [`arrow_matrix()`](https://pedrobtz.github.io/zuarrow/reference/arrow_matrix.md),
  to matrices, and maps to lists of key/value data frames. Each converts
  back.
- Factors convert to and from `dictionary<int32, utf8>`, ordered factors
  included; a stream’s batches read as the union of their levels. Other
  dictionaries and run-end encoded arrays decode to their values.
- Extension types keep their name and metadata as attributes and are
  restored on export; `arrow.bool8` reads as logical. Field metadata
  round-trips through the `arrow_field_metadata` attribute.
- [`arrow_register()`](https://pedrobtz.github.io/zuarrow/reference/arrow_register.md),
  [`arrow_unregister()`](https://pedrobtz.github.io/zuarrow/reference/arrow_register.md)
  and
  [`arrow_registry()`](https://pedrobtz.github.io/zuarrow/reference/arrow_register.md)
  let a package make a lossy type exact with its own R class, by format
  string, prefix pattern or extension name, in both directions.

### The IPC file and stream formats

- [`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md)
  reads the Arrow IPC file format (`.arrow`, Feather version 2) and
  stream format (`.arrows`) from a path, a raw vector or a connection,
  eagerly into a data frame or lazily as a stream, with column
  selection.
- LZ4 and zstd bodies are decompressed through ‘zukomp’, so a compressed
  file opens everywhere; dictionary batches and deltas are applied, and
  the binary-view, string-view, list-view and run-end-encoded layouts
  decode.
- Every message is verified and checked against
  [`arrow_limits()`](https://pedrobtz.github.io/zuarrow/reference/arrow_limits.md)
  before it is used, and every batch passes full validation, so hostile
  input is a `zuarrow_format_error` or `zuarrow_limit_error`. Big-endian
  input is refused.
- Full validation also checks that every binary or string view points
  inside its buffers, which the bundled C library does not.
- [`arrow_write()`](https://pedrobtz.github.io/zuarrow/reference/arrow_write.md)
  writes data frames, struct arrays and streams as the Arrow IPC file or
  stream format, to a path, a connection or a raw vector, in record
  batches of `batch` rows.
- Factors are written as dictionaries, one dictionary batch before the
  first record batch, or as strings with `dictionary = FALSE`; schema
  and field metadata and extension names are kept.
- `compression = "lz4"` or `"zstd"` compresses each buffer through
  ‘zukomp’, at the codec’s own `level`; the default is uncompressed, so
  every reader opens the output.
- The output is deterministic: the same input gives the same bytes, with
  no timestamps and every padding byte zeroed.
