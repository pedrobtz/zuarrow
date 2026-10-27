# zuarrow 0.0.0.9000

* Initial CRAN submission.

## Handles

* `arrow_schema()` makes a schema handle from an Arrow format string, from
  an R object, or from any schema, array or stream handle, and `format()`
  and `print()` show Arrow's type notation.
* Handles share the 'nanoarrow' package's layout and inherit from its
  classes, so handles cross between the two packages without conversion.
* `arrow_validate()` runs the bundled 'nanoarrow' C library's validation at
  `"minimal"`, `"default"` or `"full"`; `"full"` also checks that every
  string is valid UTF-8.
* `arrow_equal()` compares two schemas, arrays or streams, and says why
  they differ.
* `arrow_metadata()` and `arrow_metadata<-` read and write schema metadata,
  keeping binary values as raw vectors.
* `zuarrow_info()` reports the versions zuarrow is built from.
* Every error inherits from `zuarrow_error`, and the lossy warning from
  `zuarrow_warning`.

## Converting to and from R

* `arrow_to_r()` converts an array to an R vector and a stream or struct
  array to a data frame; `as.data.frame()` and `as.vector()` do the same,
  and `arrow_next()` reads one batch.
* A conversion is exact or it fails: `lossy = "error"`, the default
  everywhere, raises `zuarrow_lossy_error` naming the column, the row and
  the package that would read it exactly. `lossy = "character"` gives the
  values' exact text, `"warn"` and `"allow"` the nearest R type.
* `to` names the R type a column must become.
* Conversion in both directions reads and writes typed buffers in one loop
  wherever a column has no dictionary or run-end encoding, so most types
  convert as fast as with nanoarrow or faster, with every exactness check
  kept.
* `copy = FALSE` defers string columns in `arrow_to_r()`, `arrow_next()`,
  `arrow_read()` and `as.data.frame()`. Each becomes a character vector
  that creates its R strings on first use, which is most of the cost of
  a string column. Values are checked during the conversion either way,
  so the errors are the same. The default, `copy = TRUE`, creates every
  value at once.
* `arrow_array()` and `arrow_stream()` build arrays and streams from R
  vectors and data frames, checking every value against a given schema.
  The exact text that `lossy = "character"` returns is written back as the
  type its `arrow_type` attribute names.
* `arrow_types()` lists the built-in type table.

## Nested types, dictionaries and the registry

* Structs convert to nested data frames, lists of every kind to list
  columns, fixed-size lists to list columns or, with `arrow_matrix()`, to
  matrices, and maps to lists of key/value data frames. Each converts back.
* Factors convert to and from `dictionary<int32, utf8>`, ordered factors
  included; a stream's batches read as the union of their levels. Other
  dictionaries and run-end encoded arrays decode to their values.
* Extension types keep their name and metadata as attributes and are
  restored on export; `arrow.bool8` reads as logical. Field metadata
  round-trips through the `arrow_field_metadata` attribute.
* `arrow_register()`, `arrow_unregister()` and `arrow_registry()` let a
  package make a lossy type exact with its own R class, by format string,
  prefix pattern or extension name, in both directions.

## The IPC file and stream formats

* `arrow_read()` reads the Arrow IPC file format (`.arrow`, Feather
  version 2) and stream format (`.arrows`) from a path, a raw vector or a
  connection, eagerly into a data frame or lazily as a stream, with column
  selection.
* LZ4 and zstd bodies are decompressed through 'zukomp', so a compressed
  file opens everywhere; dictionary batches and deltas are applied, and the
  binary-view, string-view, list-view and run-end-encoded layouts decode.
* Every message is verified and checked against `arrow_limits()` before it
  is used, and every batch passes full validation, so hostile input is a
  `zuarrow_format_error` or `zuarrow_limit_error`. Big-endian input is
  refused.
* Full validation also checks that every binary or string view points
  inside its buffers, which the bundled C library does not.
* `arrow_write()` writes data frames, struct arrays and streams as the
  Arrow IPC file or stream format, to a path, a connection or a raw vector,
  in record batches of `batch` rows.
* Factors are written as dictionaries, one dictionary batch before the
  first record batch, or as strings with `dictionary = FALSE`; schema and
  field metadata and extension names are kept.
* `compression = "lz4"` or `"zstd"` compresses each buffer through
  'zukomp', at the codec's own `level`; the default is uncompressed, so
  every reader opens the output.
* The output is deterministic: the same input gives the same bytes, with
  no timestamps and every padding byte zeroed.

## Fixes

* A list column of data frames keeps every row of every element; before,
  its offsets counted columns, not rows, and rows were dropped (#31).
* Writing a string that is not valid UTF-8, or that is marked as `"bytes"`,
  is a `zuarrow_type_error` naming the row. Before, it built an invalid
  array or raised an unclassed error. Column names are checked the same
  way (#35).
* Writing a factor whose code names no level, or whose levels are not
  strings, is a `zuarrow_type_error` naming the row, with or without a
  dictionary (#36).
* `arrow_write()` leaves an array it writes usable. Before, it released
  the caller's array, so it could not be read or written again (#40).
* `arrow_array()` and `arrow_stream()` no longer set an attribute on the
  schema handle they are given (#53).
* Every character column switches to `large_utf8` past 2^31 - 1 bytes,
  including data frame and list columns, and `arrow_schema()` reports the
  switch (#52).
* A map column converts back to a map. A list with the
  `arrow_keys_sorted` attribute is written as `map`, and a map schema
  accepts a list of key/value data frames. A null key is a
  `zuarrow_type_error` (#41).
* `arrow_equal()` compares arrays value by value, as the design says: the
  bytes under a null slot and the array offset no longer count, and a
  dictionary or run-end encoded array compares by its decoded values (#64).
* A dictionary index outside its dictionary is a `zuarrow_format_error`
  for every dictionary, not only for factors. Before, a dictionary of
  numbers read past its end (#50).
* A factor level with an embedded NUL is cut at the NUL under
  `lossy = "warn"` or `"allow"`, as a plain string is, and the lossy error
  names the dictionary column's format. Before, it raised an unclassed
  error (#37).
* With `copy = FALSE`, strings inside list elements are copied, as the
  design says, rather than each element deferring and keeping every batch
  alive (#55).
* A decimal with a negative scale round-trips through its text form: the
  text needs the scale's trailing zeros, and zero reads as `"0"` (#54).
* Registered `to` handlers apply to the fields of nested data frames at
  any depth, as documented, and a handled field under a null struct row is
  `NA`. Before, only top-level columns used them (#42).
* An inexact registration may not replace the exact conversion of
  second and millisecond timestamps, `fixed_size_list` or the list views
  (#78).
