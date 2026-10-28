# Build an Arrow array or stream from R

`arrow_array()` converts one R vector, or a data frame, to an array
handle. `arrow_stream()` converts a data frame to a stream of record
batches of at most `batch` rows each.

## Usage

``` r
arrow_array(x, schema = NULL)

arrow_stream(x, batch = 65536L, schema = NULL)
```

## Arguments

- x:

  An R vector or a data frame.

- schema:

  `NULL`, a format string or a schema handle.

- batch:

  The largest number of rows in one batch.

## Value

`arrow_array()` returns an array handle; `arrow_stream()` a stream
handle.

## Details

Without a `schema`, each R class maps to one Arrow type: `logical` to
`bool`, `integer` to `int32`, `double` to `double`, `character` to
`utf8` (`large_utf8` past 2^31 - 1 bytes), `factor` to
`dictionary<int32, utf8>`, `Date` to `date32`, `POSIXct` to
`timestamp[us]` in its time zone or UTC, `difftime` to `duration[us]`, a
list of raw vectors to `binary`, a list with the `arrow_keys_sorted`
attribute that
[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
gives a map to `map`, any other list to `list<T>` with `T` from its
elements, and a data frame to a `struct`. A class registered with
[`arrow_register()`](https://pedrobtz.github.io/zuarrow/reference/arrow_register.md)
goes through its `from` handler, and a matrix is written as a
`fixed_size_list` with `schema = arrow_matrix()`. The attributes
`arrow_extension`, `arrow_extension_metadata` and `arrow_field_metadata`
become field metadata. Any other class is a `zuarrow_type_error`.

With a `schema`, the values are written as that type and checked: an
integer that does not fit `int8`, or a double that is not a whole number
for `int64`, is a `zuarrow_lossy_error` naming the row. `POSIXct` and
`difftime` values are rounded to the schema's unit.

A character vector with an `arrow_type` attribute, as
[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
returns under `lossy = "character"`, is written back as that type: each
value is parsed, and text that is not the type's form, or holds more
precision than the type, is an error. So the exact text round-trips.

Every `NA` becomes a null with a zeroed slot. `NaN` stays a value.

## See also

[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
for the way back,
[`arrow_types()`](https://pedrobtz.github.io/zuarrow/reference/arrow_types.md)
for the table.

## Examples

``` r
array <- arrow_array(c(1.5, NA, 3))
array
#> <zuarrow_array double[3]>
arrow_to_r(array)
#> [1] 1.5  NA 3.0

stream <- arrow_stream(data.frame(x = 1:5), batch = 2)
as.data.frame(stream)
#>   x
#> 1 1
#> 2 2
#> 3 3
#> 4 4
#> 5 5
```
