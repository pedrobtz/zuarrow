# Matrices as fixed-size lists

`arrow_matrix()` asks for a matrix where a `fixed_size_list` is
involved, in either direction. As the `schema` of
[`arrow_array()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
it writes a matrix as a `fixed_size_list` with one list per row. As a
prototype in the `to` of
[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
it reads a `fixed_size_list` column as a matrix with one row per list,
`NA` rows for null lists. Without it, a `fixed_size_list` reads as a
list column.

## Usage

``` r
arrow_matrix()
```

## Value

A marker object of class `zuarrow_matrix`.

## Examples

``` r
m <- matrix(1:6, nrow = 2)
array <- arrow_array(m, schema = arrow_matrix())
array
#> <zuarrow_array fixed_size_list(3)<item: int32>[2]>
arrow_to_r(array, to = arrow_matrix())
#>      [,1] [,2] [,3]
#> [1,]    1    3    5
#> [2,]    2    4    6
```
