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
- Every condition inherits from `zuarrow_error`.
