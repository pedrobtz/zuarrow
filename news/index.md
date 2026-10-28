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
- Conversion in both directions reads and writes typed buffers in one
  loop wherever a column has no dictionary or run-end encoding, so most
  types convert as fast as with nanoarrow or faster, with every
  exactness check kept.
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

### Fixes

- `arrow_metadata<-` raises `zuarrow_type_error` for a key that is not
  valid UTF-8 or a value that is not raw. Before, it raised a plain
  `zuarrow_error`.

- A list column of data frames keeps every row of every element; before,
  its offsets counted columns, not rows, and rows were dropped
  ([\#31](https://github.com/pedrobtz/zuarrow/issues/31)).

- Writing a string that is not valid UTF-8, or that is marked as
  `"bytes"`, is a `zuarrow_type_error` naming the row. Before, it built
  an invalid array or raised an unclassed error. Column names are
  checked the same way
  ([\#35](https://github.com/pedrobtz/zuarrow/issues/35)).

- Writing a factor whose code names no level, or whose levels are not
  strings, is a `zuarrow_type_error` naming the row, with or without a
  dictionary ([\#36](https://github.com/pedrobtz/zuarrow/issues/36)).

- [`arrow_write()`](https://pedrobtz.github.io/zuarrow/reference/arrow_write.md)
  leaves an array it writes usable. Before, it released the caller’s
  array, so it could not be read or written again
  ([\#40](https://github.com/pedrobtz/zuarrow/issues/40)).

- [`arrow_array()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
  and
  [`arrow_stream()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
  no longer set an attribute on the schema handle they are given
  ([\#53](https://github.com/pedrobtz/zuarrow/issues/53)).

- Every character column switches to `large_utf8` past 2^31 - 1 bytes,
  including data frame and list columns, and
  [`arrow_schema()`](https://pedrobtz.github.io/zuarrow/reference/arrow_schema.md)
  reports the switch
  ([\#52](https://github.com/pedrobtz/zuarrow/issues/52)).

- A map column converts back to a map. A list with the
  `arrow_keys_sorted` attribute is written as `map`, and a map schema
  accepts a list of key/value data frames. A null key is a
  `zuarrow_type_error`
  ([\#41](https://github.com/pedrobtz/zuarrow/issues/41)).

- [`arrow_equal()`](https://pedrobtz.github.io/zuarrow/reference/arrow_equal.md)
  compares arrays value by value, as the design says: the bytes under a
  null slot and the array offset no longer count, and a dictionary or
  run-end encoded array compares by its decoded values
  ([\#64](https://github.com/pedrobtz/zuarrow/issues/64)).

- A dictionary index outside its dictionary is a `zuarrow_format_error`
  for every dictionary, not only for factors. Before, a dictionary of
  numbers read past its end
  ([\#50](https://github.com/pedrobtz/zuarrow/issues/50)).

- A factor level with an embedded NUL is cut at the NUL under
  `lossy = "warn"` or `"allow"`, as a plain string is, and the lossy
  error names the dictionary column’s format. Before, it raised an
  unclassed error
  ([\#37](https://github.com/pedrobtz/zuarrow/issues/37)).

- With `copy = FALSE`, strings inside list elements are copied, as the
  design says, rather than each element deferring and keeping every
  batch alive ([\#55](https://github.com/pedrobtz/zuarrow/issues/55)).

- A decimal with a negative scale round-trips through its text form: the
  text needs the scale’s trailing zeros, and zero reads as `"0"`
  ([\#54](https://github.com/pedrobtz/zuarrow/issues/54)).

- Registered `to` handlers apply to the fields of nested data frames at
  any depth, as documented, and a handled field under a null struct row
  is `NA`. Before, only top-level columns used them
  ([\#42](https://github.com/pedrobtz/zuarrow/issues/42)).

- An inexact registration may not replace the exact conversion of second
  and millisecond timestamps, `fixed_size_list` or the list views
  ([\#78](https://github.com/pedrobtz/zuarrow/issues/78)).

- A list column with `NULL` elements writes to a `fixed_size_list`,
  whose null rows still hold their width of child values. Before, it was
  a `zuarrow_type_error`, so such a column read from Arrow could not be
  written back (found by the
  [\#48](https://github.com/pedrobtz/zuarrow/issues/48) oracle).

- [`arrow_write()`](https://pedrobtz.github.io/zuarrow/reference/arrow_write.md)
  computes a null count the producer left unknown (`-1`) before it
  writes the batch. Before, the file it wrote could not be read back
  ([\#34](https://github.com/pedrobtz/zuarrow/issues/34)).

- [`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md)
  refuses a field name or metadata key that holds a NUL or is not valid
  UTF-8 with a `zuarrow_format_error`, and so do
  [`arrow_metadata()`](https://pedrobtz.github.io/zuarrow/reference/arrow_metadata.md)
  and
  [`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
  for such a schema. Before, a NUL raised an unclassed error, a NUL in a
  name cut it short, and invalid bytes became a string marked UTF-8
  ([\#38](https://github.com/pedrobtz/zuarrow/issues/38)).

- A compression `level` outside the codec’s range, and any codec failure
  while writing, is a `zuarrow_codec_error`. Before, it was an unclassed
  `zuarrow_error`
  ([\#39](https://github.com/pedrobtz/zuarrow/issues/39)).

- [`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md)
  finds the size of a file through 64-bit offsets, so a file over 2 GiB
  opens on Windows
  ([\#51](https://github.com/pedrobtz/zuarrow/issues/51)).

- [`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md)
  reads a raw vector in place rather than copying it, except with
  `lazy = TRUE`, whose handle keeps its own copy
  ([\#57](https://github.com/pedrobtz/zuarrow/issues/57)).

- [`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md)
  refuses a file whose footer’s copy of the schema differs from its
  schema message with a `zuarrow_format_error`. Before, it read the
  message’s copy, where libarrow reads the footer’s
  ([\#33](https://github.com/pedrobtz/zuarrow/issues/33)).

- `arrow_read(lazy = TRUE)` with `to`, `lossy` or `copy` set is a
  `zuarrow_type_error`. Before, it ignored them silently
  ([\#78](https://github.com/pedrobtz/zuarrow/issues/78)).

- An unknown `lossy`, `level`, `format` or `compression` is a
  `zuarrow_type_error`, so it inherits from `zuarrow_error` like every
  other error. Before,
  [`match.arg()`](https://rdrr.io/r/base/match.arg.html) raised an
  unclassed error. The value must now match a choice exactly
  ([\#32](https://github.com/pedrobtz/zuarrow/issues/32)).

- [`arrow_write()`](https://pedrobtz.github.io/zuarrow/reference/arrow_write.md)
  raises `zuarrow_io_error` when it cannot open or write to a path or a
  connection, and the message keeps the cause, as
  [`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md)
  does. Before, a connection raised unclassed errors and a path lost the
  cause ([\#76](https://github.com/pedrobtz/zuarrow/issues/76)).

- [`as.vector()`](https://rdrr.io/r/base/vector.html) with a `mode`
  other than `"any"`, and
  [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) with
  `row.names`, are a `zuarrow_type_error`. Before, both were ignored
  silently. `optional` is documented as ignored
  ([\#77](https://github.com/pedrobtz/zuarrow/issues/77)).

- The lossy error and warning for a field of a nested data frame that is
  converted for a registered handler name its path, such as `s$b`, in
  the message and in `column`. Before, they named `b` alone
  ([\#42](https://github.com/pedrobtz/zuarrow/issues/42)).

- Error messages follow one style: “must” for a requirement and “can’t”
  for what is impossible, one idea per sentence
  ([\#80](https://github.com/pedrobtz/zuarrow/issues/80)).

- A list column of functions, environments or calls is a
  `zuarrow_type_error`. Before, `arrow_schema(list(sum))` recursed until
  the C stack overflowed
  ([\#82](https://github.com/pedrobtz/zuarrow/issues/82)).
