
<!-- README.md is generated from README.Rmd. Please edit that file -->

# zuarrow

<!-- badges: start -->

[![R-CMD-check](https://github.com/pedrobtz/zuarrow/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/pedrobtz/zuarrow/actions/workflows/R-CMD-check.yaml)
[![coverage](https://raw.githubusercontent.com/pedrobtz/zuarrow/gh-pages/badges/coverage.svg)](https://github.com/pedrobtz/zuarrow/actions/workflows/coverage.yaml)
[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
<!-- badges: end -->

DuckDB, Polars, ADBC drivers, pyarrow and the arrow package all hand
data around as [Apache Arrow](https://arrow.apache.org/) columns. R has
no exact form for several of Arrow’s types: a 64-bit integer past 2^53,
a `decimal128`, a nanosecond timestamp. The usual bridges convert them
to a double anyway, and the change goes unnoticed until a join key no
longer matches.

zuarrow moves columns between R and Arrow on one rule: **a value crosses
exactly, or the call fails**, naming the column and the R type that
would hold it.

- **Exact or error.** `lossy = "error"` is the default everywhere. Ask
  for the exact text, the nearest R type with a warning, or the nearest
  R type silently, but only by asking.
- **A registry for exact types.** A package registers its class for an
  Arrow type with `arrow_register()`, and from then on that column
  converts exactly.
- **Both IPC formats.** `arrow_read()` and `arrow_write()` handle the
  file (`.arrow`, Feather version 2) and the stream (`.arrows`), with
  LZ4 and zstd bodies decompressed by
  [zukomp](https://github.com/pedrobtz/zukomp), so a compressed file
  opens on every machine.
- **Hostile input is refused, not trusted.** Every message is checked
  against limits before it is used and every batch is fully validated.
  The reader is fuzzed and checked against Arrow’s own conformance
  files.
- **nanoarrow’s handles.** zuarrow’s schemas, arrays and streams are
  [nanoarrow](https://arrow.apache.org/nanoarrow/)’s, so they pass
  between the two packages without conversion.

## Installation

zuarrow is not on CRAN yet. Install the development version from GitHub:

``` r
# install.packages("pak")
pak::pak("pedrobtz/zuarrow")
```

## Usage

``` r
library(zuarrow)
```

Ordinary columns cross both ways unchanged, factors and dates included.

``` r
df <- data.frame(
  id = 1:3,
  city = factor(c("Lisbon", "Porto", "Lisbon")),
  day = as.Date("2026-10-21") + 0:2
)
identical(arrow_to_r(arrow_array(df)), df)
#> [1] TRUE
```

A 64-bit integer that a double cannot hold is an error, not a rounding.

``` r
big <- arrow_array(c("9007199254740993", "1"), schema = "l")
arrow_to_r(big)
#> Error in `arrow_to_r()`:
#> ! Column 1 (Arrow format `l`) can't be converted to R exactly: row 1 holds 9007199254740993. Load zuint to read it exactly, or use `lossy = "character"` for its exact text, or `lossy = "allow"` to accept the loss.
```

`lossy = "character"` gives the exact text, which writes back to the
same type.

``` r
text <- arrow_to_r(big, lossy = "character")
text
#> [1] "9007199254740993" "1"               
#> attr(,"arrow_type")
#> [1] "l"
arrow_equal(arrow_array(text), big)
#> [1] TRUE
```

The IPC formats are one call each way, with compression on request.

``` r
path <- tempfile(fileext = ".arrow")
arrow_write(df, path, compression = "zstd")
arrow_read(path)
#>   id   city        day
#> 1  1 Lisbon 2026-10-21
#> 2  2  Porto 2026-10-22
#> 3  3 Lisbon 2026-10-23
```

Apart from `zuarrow_info()`, every function is prefixed `arrow_`. Each
takes or returns a handle or a plain R object. zuarrow’s own errors
inherit from `zuarrow_error`, with a class for each kind, such as
`zuarrow_lossy_error`.

## Learn more

- [Receiving a DuckDB result without
  rounding](https://pedrobtz.github.io/zuarrow/articles/duckdb.html)
  shows the headline use.
- The [reference](https://pedrobtz.github.io/zuarrow/reference/) lists
  every function; `arrow_types()` prints the type table.

## Related work

zuarrow bundles the
[nanoarrow](https://github.com/apache/arrow-nanoarrow) C library and is
checked against
[apache/arrow-testing](https://github.com/apache/arrow-testing)’s IPC
golden files and crash corpus, and against the arrow package.
