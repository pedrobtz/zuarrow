# Compare two schemas, arrays or streams

Two schemas are equal when their formats, names, flags and children
match, and their metadata too unless `metadata = FALSE`. Two arrays are
equal when their schemas are and they hold the same values, compared
value by value: a null equals a null whatever bytes lie under it, and
offsets do not matter. A dictionary or run-end encoded array compares by
the values it decodes to. Two streams are equal when their schemas are
and they yield the same number of batches, each pair equal. Comparing
streams reads them both to the end.

## Usage

``` r
arrow_equal(x, y, metadata = TRUE)
```

## Arguments

- x, y:

  Two handles of the same kind.

- metadata:

  Whether schema and field metadata must match too.

## Value

`TRUE` or `FALSE`. `FALSE` carries a `reason` attribute naming the first
difference.

## Examples

``` r
arrow_equal(arrow_schema("i"), arrow_schema("i"))
#> [1] TRUE
arrow_equal(arrow_schema("i"), arrow_schema("l"))
#> [1] FALSE
#> attr(,"reason")
#> [1] "format 'i' differs from 'l'"
```
