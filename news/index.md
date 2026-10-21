# Changelog

## zuarrow 0.0.0.9000

- Initial CRAN submission.

### Handles and schema tools

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

### Conversion

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
- [`arrow_array()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
  and
  [`arrow_stream()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
  build arrays and streams from R vectors and data frames, checking
  every value against a given schema. The exact text that
  `lossy = "character"` returns is written back as the type its
  `arrow_type` attribute names.
- [`arrow_types()`](https://pedrobtz.github.io/zuarrow/reference/arrow_types.md)
  lists the built-in type table.
