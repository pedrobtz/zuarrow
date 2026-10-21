# Read the Arrow IPC formats

`arrow_read()` reads an Arrow IPC file, with its footer (`.arrow`, also
called Feather version 2), or an IPC stream (`.arrows`). The framing is
found from the first bytes, whatever the source is called.

## Usage

``` r
arrow_read(
  x,
  columns = NULL,
  lazy = FALSE,
  to = NULL,
  lossy = zar_lossy_policies,
  limits = arrow_limits()
)
```

## Arguments

- x:

  A path, a raw vector, or a connection, which is read to its end.

- columns:

  `NULL` for every column, or the names or positions of the top-level
  columns to read. Only those are decoded.

- lazy:

  `FALSE` to read every batch into one data frame; `TRUE` to return a
  stream handle whose batches are decoded by
  [`arrow_next()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md).

- to:

  `NULL`, or a named list of prototypes, one per column. For an array
  that is not a `struct`, a single prototype.

- lossy:

  What to do with a column R cannot hold exactly.

- limits:

  An
  [`arrow_limits()`](https://pedrobtz.github.io/zuarrow/reference/arrow_limits.md)
  object.

## Value

A data frame, or with `lazy = TRUE` a stream handle.

## Details

The input is checked before it is used: every message is verified, every
buffer must lie inside its message, and every limit of
[`arrow_limits()`](https://pedrobtz.github.io/zuarrow/reference/arrow_limits.md)
binds, so malformed or hostile bytes are a `zuarrow_format_error` or a
`zuarrow_limit_error`, never a crash. Each batch then passes the full
validation of
[`arrow_validate()`](https://pedrobtz.github.io/zuarrow/reference/arrow_validate.md)
before it is converted. Bodies compressed with LZ4 or zstd are
decompressed through 'zukomp'. Big-endian input is a
`zuarrow_format_error`.

Dictionary batches, and the deltas a stream may send between record
batches, are applied as the format says; a file that replaces a
dictionary is an error, as the format forbids it.

## See also

[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
for the conversion and its `lossy` policy.

## Examples

``` r
path <- tempfile(fileext = ".arrows")
stream <- arrow_stream(data.frame(x = 1:3, y = c("a", "b", "c")))
if (requireNamespace("nanoarrow", quietly = TRUE)) {
  nanoarrow::write_nanoarrow(stream, path)
  arrow_read(path)
}
#>   x y
#> 1 1 a
#> 2 2 b
#> 3 3 c
```
