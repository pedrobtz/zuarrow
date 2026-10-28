# Write the Arrow IPC formats

`arrow_write()` writes a data frame, a `struct` array or a stream as an
Arrow IPC file (`format = "file"`, with a footer) or stream
(`format = "stream"`). A path ending in `.arrows` defaults to the stream
format; any other path, and `x = NULL`, to the file format.

## Usage

``` r
arrow_write(
  data,
  x = NULL,
  format = c("file", "stream"),
  compression = c("none", "lz4", "zstd"),
  level = NULL,
  batch = 65536L,
  dictionary = TRUE,
  metadata = NULL
)
```

## Arguments

- data:

  A data frame, a struct array handle or a stream handle.

- x:

  `NULL` to return the bytes, a path, or a connection.

- format:

  `"file"` or `"stream"`.

- compression:

  `"none"`, `"lz4"` or `"zstd"`.

- level:

  `NULL` for the codec's default, or a level on its scale. A level
  outside the codec's range is a `zuarrow_codec_error`.

- batch:

  The most rows in one record batch, for a data frame.

- dictionary:

  Whether factors are written as dictionaries.

- metadata:

  `NULL`, or a named character vector of schema metadata.

## Value

A raw vector when `x` is `NULL`, otherwise `x`, invisibly.

## Details

A data frame is split into record batches of at most `batch` rows. Each
factor is written as a dictionary with one dictionary batch before the
first record batch, or as plain strings with `dictionary = FALSE`.
Columns with `arrow_extension`, `arrow_extension_metadata` or
`arrow_field_metadata` attributes keep them as field metadata, and
`metadata` becomes the schema's custom metadata.

Bodies are padded to 8 bytes with zeros and are uncompressed by default,
so every reader opens the file. `compression = "lz4"` writes LZ4 frames
and `"zstd"` zstd frames through 'zukomp', at `level` on the codec's own
scale; a buffer that does not shrink is written as it is. The same input
and options give the same bytes on every platform.

## See also

[`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md).

## Examples

``` r
df <- data.frame(x = 1:3, f = factor(c("a", "b", "a")))
bytes <- arrow_write(df, NULL)
arrow_read(bytes)
#>   x f
#> 1 1 a
#> 2 2 b
#> 3 3 a

path <- tempfile(fileext = ".arrows")
arrow_write(df, path, compression = "zstd")
arrow_read(path)
#>   x f
#> 1 1 a
#> 2 2 b
#> 3 3 a
```
