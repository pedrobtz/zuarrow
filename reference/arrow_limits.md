# Limits on IPC input

`arrow_limits()` bounds what
[`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md)
accepts from untrusted input. Each limit is checked before the bytes it
covers are used, and going over one is a `zuarrow_limit_error`.

## Usage

``` r
arrow_limits(
  max_message = 2^31 - 1,
  max_depth = 64L,
  max_batch_rows = 2^31 - 1,
  max_bytes = Inf
)
```

## Arguments

- max_message:

  The most bytes one message header or body may hold, and the most bytes
  one compressed buffer may claim when decompressed.

- max_depth:

  The deepest nesting a schema may have.

- max_batch_rows:

  The most rows one record batch may hold.

- max_bytes:

  The most bytes of input in all.

## Value

A list of class `zuarrow_limits`.

## Examples

``` r
arrow_limits(max_bytes = 2^30)
#> $max_message
#> [1] 2147483647
#> 
#> $max_depth
#> [1] 64
#> 
#> $max_batch_rows
#> [1] 2147483647
#> 
#> $max_bytes
#> [1] 1073741824
#> 
#> attr(,"class")
#> [1] "zuarrow_limits"
```
