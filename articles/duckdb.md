# Receiving a DuckDB result without rounding

DuckDB stores `BIGINT` as a 64-bit integer and `DECIMAL(38, 0)` as a
128-bit one. R’s numbers are doubles, which hold every integer up to
2^53 and only some beyond it. A query that returns an identifier, an
amount in cents or a nanosecond timestamp past that point comes back
changed, and nothing says so.

This article shows the change happening, then the same result received
through zuarrow, which either returns every value exactly or stops and
says which column could not be.

``` r

library(zuarrow)
con <- DBI::dbConnect(duckdb::duckdb(shared_home = FALSE))
```

## The silent change

The query returns two keys. The first is 2^53 + 1, the smallest integer
a double cannot hold.

``` r

sql <- "SELECT * FROM (VALUES (9007199254740993::BIGINT, 'a'),
                              (1::BIGINT, 'b')) AS t(key, label)"
```

DBI returns it as a double, rounded to its neighbour.

``` r

res <- DBI::dbGetQuery(con, sql)
format(res$key, scientific = FALSE)
#> [1] "9007199254740992" "               1"
```

A join against the exact key would now miss this row.

## Exact or error

[`arrow_duckdb()`](https://pedrobtz.github.io/zuarrow/reference/arrow_duckdb.md)
runs the same query and receives the result as an Arrow stream, which
zuarrow converts directly. By default it refuses, and the error names
the column, the row and the ways to receive it exactly.

``` r

arrow_duckdb(con, sql)
#> Error in `arrow_duckdb()`:
#> ! Column `key` (Arrow format `l`) can't be converted to R exactly: row 1 holds 9007199254740993. Load zuint to read it exactly, or use `lossy = "character"` for its exact text, or `lossy = "allow"` to accept the loss.
```

With `lossy = "character"` the key arrives as its exact text, and
[`arrow_array()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
turns that text back into the same `int64`.

``` r

out <- arrow_duckdb(con, sql, lossy = "character")
out$key
#> [1] "9007199254740993" "1"               
#> attr(,"arrow_type")
#> [1] "l"
arrow_array(out$key)
#> <zuarrow_array int64[2]>
```

A package that registers an exact class for `int64`, such as zuint,
makes the default conversion exact, with no argument at all.

## Columns that fit

Only columns whose values cannot be held exactly are refused. Keys
within 2^53 arrive as ordinary doubles under the default.

``` r

str(arrow_duckdb(con, "SELECT 42::BIGINT AS key, DATE '2026-10-21' AS day"))
#> 'data.frame':    1 obs. of  2 variables:
#>  $ key: num 42
#>  $ day: Date, format: "2026-10-21"
```

## 128-bit integers

[`arrow_duckdb()`](https://pedrobtz.github.io/zuarrow/reference/arrow_duckdb.md)
turns on DuckDB’s `arrow_lossless_conversion` for the query and puts it
back afterwards. `HUGEINT` then arrives as the `arrow.opaque` extension
over 16 bytes, rather than as a `DECIMAL(38, 0)` that a decimal package
would read as a decimal. With nothing registered for it, the column
keeps its bytes and its extension.

``` r

h <- arrow_duckdb(con, "SELECT 1::HUGEINT AS h")$h
h[[1]]
#>  [1] 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
attr(h, "arrow_extension")
#> [1] "arrow.opaque"
```
