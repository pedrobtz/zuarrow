# Arrow schemas

`arrow_schema()` makes a schema handle from a format string, from an R
object, or from any schema, array or stream handle. A handle can come
from zuarrow, from 'nanoarrow' or from any producer that uses its
layout, such as 'arrow', 'duckdb' or an 'ADBC' driver.

## Usage

``` r
arrow_schema(x)
```

## Arguments

- x:

  A format string, an R object, or a schema, array or stream handle.

## Value

A schema handle of class `c("zuarrow_schema", "nanoarrow_schema")`.

## Details

A single string is read as an Arrow format string, such as `"i"` for
`int32` or `"tsu:UTC"` for a microsecond timestamp in UTC. Any other R
object gives the schema it would be written with: a data frame gives a
`struct` with one field per column. On a handle, `arrow_schema()` never
raises on the content: it returns a zuarrow schema handle as it is,
copies any other schema, or asks a stream for it.

[`format()`](https://rdrr.io/r/base/format.html) gives the type notation
Arrow's own tools print, such as `int64` or `struct<x: int32>`, and
[`print()`](https://rdrr.io/r/base/print.html) shows it.

## See also

[`arrow_metadata()`](https://pedrobtz.github.io/zuarrow/reference/arrow_metadata.md)
for schema metadata,
[`arrow_equal()`](https://pedrobtz.github.io/zuarrow/reference/arrow_equal.md)
to compare schemas.

## Examples

``` r
arrow_schema("l")
#> <zuarrow_schema> int64
arrow_schema(data.frame(x = 1:3, y = c("a", "b", "c")))
#> <zuarrow_schema> struct<x: int32, y: string>
format(arrow_schema(as.Date("2026-10-21")))
#> [1] "date32"
```
