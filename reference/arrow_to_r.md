# Convert Arrow data to R

`arrow_to_r()` converts an array to an R vector, and a stream or a
`struct` array to a data frame with one column per field. The result
carries no zuarrow class: it is a plain base R object.

## Usage

``` r
arrow_to_r(x, to = NULL, lossy = zar_lossy_policies)

arrow_next(stream, to = NULL, lossy = zar_lossy_policies)
```

## Arguments

- x:

  An array or stream handle.

- to:

  `NULL`, or a named list of prototypes, one per column. For an array
  that is not a `struct`, a single prototype.

- lossy:

  What to do with a column R cannot hold exactly.

- stream:

  A stream handle.

## Value

An R vector, or a data frame.

`arrow_next()` returns the next batch as a data frame (or a vector, for
a stream that is not of `struct`), or `NULL` once the stream has ended.

## Details

A conversion is exact or it fails. `lossy` decides what happens to a
column that R cannot hold exactly, such as an `int64` with a value past
2^53, a `decimal128`, or a nanosecond timestamp:

- `"error"`, the default, raises `zuarrow_lossy_error`, naming the
  column, the Arrow type, the first offending row where there is one,
  and the package that would read the column exactly.

- `"character"` returns the values' exact text: integers as digits,
  decimals with their scale, timestamps in ISO 8601 at the type's
  precision. The column carries the Arrow format string in its
  `arrow_type` attribute.

- `"warn"` converts to the nearest R type and raises one
  `zuarrow_lossy_warning` per column.

- `"allow"` converts to the nearest R type silently. An `int64` column
  becomes `bit64`'s `integer64`, exactly, when `bit64` is loaded.

Intervals and unions have no R form and always fail.

`to` names the R type a column must become:
[`character()`](https://rdrr.io/r/base/character.html),
[`double()`](https://rdrr.io/r/base/double.html),
[`integer()`](https://rdrr.io/r/base/integer.html), or
[`arrow_matrix()`](https://pedrobtz.github.io/zuarrow/reference/arrow_matrix.md)
for a `fixed_size_list`. A target that cannot take the column is a
`zuarrow_type_error`, never a silent fallback.

Nested types follow the table too. A `struct` becomes a data frame
column; `list`, `large_list` and the list views become list columns,
`NULL` for a null list; a `map` becomes a list of data frames with
columns `key` and `value`. A dictionary of strings becomes a factor,
ordered when the dictionary is, with the union of every batch's levels;
a dictionary of other values, and a run-end encoded array, decode to
their values' R form. An extension type converts as its storage and
keeps its name and metadata in the `arrow_extension` and
`arrow_extension_metadata` attributes, so writing the column back
restores it. Field metadata becomes the `arrow_field_metadata`
attribute. A type registered with
[`arrow_register()`](https://pedrobtz.github.io/zuarrow/reference/arrow_register.md)
goes through its handler.

## See also

[`arrow_array()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
for the way there,
[`arrow_types()`](https://pedrobtz.github.io/zuarrow/reference/arrow_types.md)
for the table.

## Examples

``` r
arrow_to_r(arrow_array(1:3))
#> [1] 1 2 3

big <- arrow_array(2^53 + 2, schema = "l")
try(arrow_to_r(big))
#> Error in arrow_to_r(big) : 
#>   Column 1 (Arrow format `l`) cannot be converted to R exactly: row 1 holds 9007199254740994. Load zuint to read it exactly, or use `lossy = "character"` for its exact text, or `lossy = "allow"` to accept the loss.
arrow_to_r(big, lossy = "character")
#> [1] "9007199254740994"
#> attr(,"arrow_type")
#> [1] "l"
```
