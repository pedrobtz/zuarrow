# zuarrow 0.0.0.9000

* Initial CRAN submission.

## Handles and schema tools

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

## Conversion

* `arrow_to_r()` converts an array to an R vector and a stream or struct
  array to a data frame; `as.data.frame()` and `as.vector()` do the same,
  and `arrow_next()` reads one batch.
* A conversion is exact or it fails: `lossy = "error"`, the default
  everywhere, raises `zuarrow_lossy_error` naming the column, the row and
  the package that would read it exactly. `lossy = "character"` gives the
  values' exact text, `"warn"` and `"allow"` the nearest R type.
* `to` names the R type a column must become.
* `arrow_array()` and `arrow_stream()` build arrays and streams from R
  vectors and data frames, checking every value against a given schema.
  The exact text that `lossy = "character"` returns is written back as the
  type its `arrow_type` attribute names.
* `arrow_types()` lists the built-in type table.

## Nested types, dictionaries, extensions and the registry

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
