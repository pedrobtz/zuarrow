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
* An error names the function or S3 method you called, such as
  `arrow_stream()` or `as.data.frame()`, never an internal helper (#124).

## Converting to and from R

* `arrow_to_r()` converts an array to an R vector and a stream or struct
  array to a data frame; `as.data.frame()` and `as.vector()` do the same,
  and `arrow_next()` reads one batch.
* A conversion is exact or it fails: `lossy = "error"`, the default
  everywhere, raises `zuarrow_lossy_error` naming the column, the row and
  the package that would read it exactly. `lossy = "character"` gives the
  values' exact text, `"warn"` and `"allow"` the nearest R type.
* A column with no values is never lossy: under `"error"` and `"warn"` it
  takes the form `"allow"` gives, so reading a zero-row result, as
  dbplyr does for a table's columns, no longer fails (#177).
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
  type its `arrow_type` attribute names. Only that canonical text is read,
  so other forms of a value, such as `"+1"` or `"01"`, and a time of day of
  `24:00:00` are a `zuarrow_lossy_error` (#213).
* A value that would not export exactly is a `zuarrow_type_error`: a
  non-ASCII native string with no exact UTF-8 form, as in a C locale (#203);
  a matrix under a schema that is not a list type, or with a class (#209);
  a factor with an `NA` level (#211); a `tzone`, difftime `units` or
  `arrow_extension_metadata` attribute that is not one valid value (#214).
* `arrow_types()` lists the built-in type table.

## Nested types, dictionaries and the registry

* Structs convert to nested data frames, lists of every kind to list
  columns, fixed-size lists to list columns or, with `arrow_matrix()`, to
  matrices, and maps to lists of key/value data frames. Each converts back.
* Factors convert to and from `dictionary<int32, utf8>`, ordered factors
  included; a stream's batches read as the union of their levels. Other
  dictionaries and run-end encoded arrays decode to their values.
* A `fixed_size_binary` column read as a list of raw vectors keeps its
  width in `arrow_width`, and is written back as `fixed_size_binary` (#210).
* Extension types keep their name and metadata as attributes and are
  restored on export; `arrow.bool8` reads as logical. Field metadata
  round-trips through the `arrow_field_metadata` attribute.
* `arrow_register()`, `arrow_unregister()` and `arrow_registry()` let a
  package make a lossy type exact with its own R class, by format string,
  prefix pattern or extension name, in both directions.
* A `to` handler of `(array, schema, lossy)` receives the caller's `lossy`
  policy, so a registering package applies it to values its class cannot
  hold. Two-argument handlers work as before. When several keys match, the
  extension name wins, then the exact format, then the earliest pattern.
* A prototype of a registered class in `to`, such as `zuint::int128()`,
  converts a column through that registration whatever its Arrow type.
* A registered extension over a `dense_union` or `sparse_union`, such as
  `geoarrow.geometry`, reads through its `to` handler, which receives the
  union array with its type ids, offsets and children as they are. A union
  with no handler still fails with a `zuarrow_lossy_error` (#171).

## The IPC file and stream formats

* `arrow_read()` reads the Arrow IPC file format (`.arrow`, Feather
  version 2) and stream format (`.arrows`) from a path, a raw vector or a
  connection, eagerly into a data frame or lazily as a stream, with column
  selection.
* `arrow_read()` also takes a list of IPC streams and reads them as one,
  as Spark Connect sends a result: one data frame, or with `lazy = TRUE`
  one stream. Every stream must have the first one's schema.
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

* A lossy value in a dictionary or run-end encoded column is checked as
  the rows read it. The `zuarrow_lossy_error` names its row, and a value
  that no row reads, or that only null rows read, is not lossy. Before,
  any such value in the dictionary or the runs raised an error with no
  row (#107).
* The `zuarrow_lossy_error` of a dictionary column names the package that
  reads its value type exactly, such as 'zuint' for `int64` values, as a
  run-end encoded column's does. It used to look the target up by the
  index type and name none (#144).

* `arrow_array()` refuses a list column of data frames whose elements
  differ in column names, column order, or a column's class, type or
  attributes, with a `zuarrow_type_error` naming the column. It used to
  let `rbind()` coerce an integer column to character. A plain factor
  column's levels may still differ; an ordered factor's may not (#103).

* `arrow_array()` refuses a list column of ordered factors whose levels
  differ, with a `zuarrow_type_error`. It used to write them as one plain
  factor with the union of their levels, so they read back unordered.
  Elements with the same levels still round-trip as ordered factors
  (#138).

* `arrow_schema()` of a registered vector, or of a data frame holding one,
  takes the type from the whole column, as `arrow_array()` does. A `from`
  handler that picks the type from the values gave the two a different
  type before (#113).
* An object goes through the registration of its most specific class: an
  object of class `c("sub", "base")` uses the `"sub"` registration, in
  `arrow_array()` and as a prototype in `to`, whichever loaded first. It
  used to use the one registered first (#114).
* A package that registers a pattern again, as on a reload, keeps the
  pattern's place among overlapping patterns. It used to move last (#115).
* `arrow_array()` of a registered vector is a `zuarrow_registry_error`
  when the `from` handler builds an array of another length, as it is for
  a data frame column, and a `zuarrow_handle_error` when the handler
  returns a released array (#123).
* An extension whose storage type converts exactly stays exact. An
  inexact registration for `arrow.json` or `arrow.uuid` is refused, and
  one for another extension name is a `zuarrow_registry_error` when it
  would read a column of exact storage under `lossy = "warn"` or
  `"allow"` (#133).

* A `POSIXct` round-trips through Arrow under the default policy.
  Millisecond and microsecond timestamps are exact by value: a value is
  exact when its double of seconds rounds back to the same integer, and
  only one that does not is a `zuarrow_lossy_error` naming its row. Before,
  every microsecond timestamp was lossy, so zuarrow could not read back
  what it wrote, and the millisecond bound of 2^53 let a few values past
  2^51 through inexactly (#130).

* `arrow_read()` applies a delta dictionary batch that extends a
  dictionary already holding values, for fixed-width, binary and string
  values. Before, the bundled decoder refused it with a
  `zuarrow_format_error` (#81).
* `arrow_write()` writes a dictionary of struct or list values with the
  value type's children in the schema. Before, the bundled encoder dropped
  them, so the output could not be read back (#140).

* `arrow_read()` bounds what delta dictionaries build. Each delta copies
  the whole dictionary, so many small deltas could take memory and time
  quadratic in their number. A dictionary that deltas extend is now held to
  `max_batch_rows` values and `max_message` bytes, and every byte the
  copies build counts against the new `max_dictionary` limit of
  `arrow_limits()`, 256 MiB by default. Going over one is a
  `zuarrow_limit_error` (#101).
* A stream whose next batch fails raises the same class from every
  function: a `zuarrow_format_error`, `zuarrow_limit_error` or
  `zuarrow_codec_error` from zuarrow's IPC reader, and a
  `zuarrow_handle_error` from any other producer. Before,
  `arrow_validate()` and `arrow_equal()` always raised a handle error
  (#83).
* A registered `from` handler is called once on the whole column, and the
  column takes the type of the array it returns. So a handler may choose
  the type from the values, as `decimal` chooses a precision, and
  `arrow_write()` and `arrow_stream()` write the column in batches of that
  type (#91).
* A registered `from` handler that builds a batch whose nested type
  differs from the column's, such as `list<int32>` in a `list<int64>`
  column, raises a `zuarrow_registry_error`. Before, only the top-level
  format was compared, so the batch's bytes were read as the wrong type
  (#100).
* A zero-row data frame is a stream of one zero-row batch, as it is one
  zero-row array, so `arrow_stream()` and `arrow_write()` keep a factor's
  levels, nested ones too. Before, the stream had no batch and the levels
  were lost (#212).
* A registered `from` handler is called once on the whole column for
  every layout, and each batch is a copy of that array's rows. Before, a
  column that was not fixed-width was built again per batch from
  `x[rows]`, which drops the class and attributes. A sliced run-end
  encoded column is now written as its rows, not refused (#215).
* A `to` handler's piece for each batch must have that batch's length, or
  it is a `zuarrow_registry_error` naming the batch. Before, only the
  total was checked, so rows could shift between batches (#216).
* A `to` handler's data frame pieces are combined column by column, and
  pieces whose class `c()` drops keep the attributes they share. Pieces
  whose attributes differ are a `zuarrow_registry_error`. Before, several
  batches could give another class or another shape than one batch
  (#198).
* A dictionary or run-end encoded column goes to the handler registered
  for its value type, which receives the decoded values. Before, the
  handler for the index type received the dictionary, so a dictionary
  with `int64` indices went to an `int64` registration and was read
  wrong, and a dictionary of decimals did not reach decimal's (#93).
* A package that registers a key it already owns, as on every reload,
  does so without a message (#92).
* A registered `from` handler that returns a released array raises a
  `zuarrow_handle_error`. Before, it raised a base error (#126).
* `arrow_to_r()` and `arrow_equal()` check every offset of an array from
  another producer before reading it. A string, binary or list offset that
  decreases or points past its data is a `zuarrow_format_error`, and so is
  a string view outside its buffers in `arrow_equal()`. Before,
  `arrow_to_r()` read past the buffer or raised an unclassed error, and
  `arrow_equal()` could crash R (#102).
* `arrow_write()` and the decoder that hands a dictionary's or run-end
  encoded column's values to a registered handler check every offset the
  same way. Before, `arrow_write()` wrote a batch whose string offsets
  decrease or point past its data into a file no reader accepts (#150).
* `arrow_read(lazy = TRUE)` on a list of sources is lazy: `arrow_next()`
  decodes one batch at a time, stream after stream, and frees each source
  once it is read. Before, every batch was decoded when the handle was
  made. `max_bytes` now binds the sources together for paths and
  connections too, not only for raw vectors (#116).
* `arrow_read()` raises `zuarrow_type_error` for a column position that
  is infinite or past the integer range. Before, it warned and raised an
  unclassed error (#125).

* `arrow_write()` writes a sliced batch, one with a non-zero offset at any
  depth, as the values it holds, as `arrow`, DuckDB and 'nanoarrow' slices
  produce. Every writer failure now has a class: a view layout, a sliced
  run-end encoded column and a batch with null rows are a
  `zuarrow_type_error`, and a malformed batch is a `zuarrow_format_error`.
  Before, these raised an unclassed `zuarrow_error` (#104).

* `arrow_metadata<-` raises `zuarrow_type_error` for a key that is not
  valid UTF-8 or a value that is not raw. Before, it raised a plain
  `zuarrow_error`.

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
* A list column with `NULL` elements writes to a `fixed_size_list`, whose
  null rows still hold their width of child values. Before, it was a
  `zuarrow_type_error`, so such a column read from Arrow could not be
  written back (found by the #48 oracle).
* `arrow_write()` computes a null count the producer left unknown (`-1`)
  before it writes the batch. Before, the file it wrote could not be read
  back (#34).
* Full validation bounds a large list view's offset plus size without
  overflowing a 64-bit integer. Before, two large values wrapped around and
  passed the check, so a hostile IPC input was read out of bounds (#85).
* `arrow_read()` refuses a field name or metadata key that holds a NUL or
  is not valid UTF-8 with a `zuarrow_format_error`, and so do
  `arrow_metadata()` and `arrow_to_r()` for such a schema. Before, a NUL
  raised an unclassed error, a NUL in a name cut it short, and invalid
  bytes became a string marked UTF-8 (#38).
* A compression `level` outside the codec's range, and any codec failure
  while writing, is a `zuarrow_codec_error`. Before, it was an unclassed
  `zuarrow_error` (#39).
* `arrow_read()` finds the size of a file through 64-bit offsets, so a file
  over 2 GiB opens on Windows (#51).
* `arrow_read()` reads a raw vector in place rather than copying it, except
  with `lazy = TRUE`, whose handle keeps its own copy (#57).
* `arrow_read()` refuses a file whose footer's copy of the schema differs
  from its schema message with a `zuarrow_format_error`. Before, it read
  the message's copy, where libarrow reads the footer's (#33).
* `arrow_read(lazy = TRUE)` with `to`, `lossy` or `copy` set is a
  `zuarrow_type_error`. Before, it ignored them silently (#78).
* An unknown `lossy`, `level`, `format` or `compression` is a
  `zuarrow_type_error`, so it inherits from `zuarrow_error` like every
  other error. Before, `match.arg()` raised an unclassed error. The value
  must now match a choice exactly (#32).
* `arrow_write()` raises `zuarrow_io_error` when it cannot open or write
  to a path or a connection, and the message keeps the cause, as
  `arrow_read()` does. Before, a connection raised unclassed errors and a
  path lost the cause (#76).
* `as.vector()` with a `mode` other than `"any"`, and `as.data.frame()`
  with `row.names`, are a `zuarrow_type_error`. Before, both were ignored
  silently. `optional` is documented as ignored (#77).
* The lossy error and warning for a field of a nested data frame that is
  converted for a registered handler name its path, such as `s$b`, in the
  message and in `column`. Before, they named `b` alone (#42).
* Error messages follow one style: "must" for a requirement and "can't"
  for what is impossible, one idea per sentence (#80).
* A list column of functions, environments or calls is a
  `zuarrow_type_error`. Before, `arrow_schema(list(sum))` recursed until
  the C stack overflowed (#82).
* `arrow_read()` reads a schema nested up to `max_depth` levels and
  refuses a deeper one with a `zuarrow_limit_error`. Before, the bundled
  FlatBuffers verifier ran out of its own budget from 49 levels, and its
  failure took time exponential in the depth, so a stream of a few KB,
  or one written by `arrow_write()`, stalled the session (#200).
* `arrow_write()` writes a field with no name with an empty name, as
  `arrow_read()` presents it. Before, an `NA` column name crashed R (#201).
* `arrow_write()` writes metadata values whole. Before, schema, field and
  extension metadata were cut at the first NUL byte (#202).
* A stream handle from `arrow_read(lazy = TRUE)` stays failed after an
  error: every later `arrow_next()`, and every later `get_next()` through
  the C stream interface, raises the same error. Before, the reader went
  on to the next message, so a batch was skipped or read against the
  dictionary that a failed replacement should have replaced (#207).
* `arrow_read()` refuses a record batch or dictionary batch whose length
  differs from its columns' lengths, as a `zuarrow_format_error`, as
  `arrow` does. Before, a batch shorter than its columns dropped rows
  silently (#208).
* `arrow_write()` writes a batch whose columns are longer than it, as a
  zero-offset slice of an `arrow` struct array is, at the batch's length.
  Before, each column kept its own length, and `arrow` refused the
  output (#206).
* `arrow_write()` writes a dictionary whose values hold another dictionary
  after that inner dictionary, as the format requires. Before, it wrote
  the outer one first, and `arrow_read()` refused the output (#186).
