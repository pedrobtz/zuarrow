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
con <- DBI::dbConnect(duckdb::duckdb())
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

DuckDB can hand over the same result as an Arrow stream, which zuarrow
converts directly.

``` r

fetch_arrow <- function(con, sql) {
  res <- DBI::dbSendQuery(con, sql, arrow = TRUE)
  on.exit(DBI::dbClearResult(res))
  reader <- duckdb::duckdb_fetch_record_batch(res)
  stream <- nanoarrow::as_nanoarrow_array_stream(reader)
  arrow_to_r(stream, lossy = "character")
}
```

By default the conversion refuses, and the error names the column, the
row and the ways to receive it exactly.

``` r

res <- DBI::dbSendQuery(con, sql, arrow = TRUE)
stream <- nanoarrow::as_nanoarrow_array_stream(
  duckdb::duckdb_fetch_record_batch(res)
)
arrow_to_r(stream)
#> Error in `arrow_to_r()`:
#> ! Column `key` (Arrow format `l`) cannot be converted to R exactly: row 1 holds 9007199254740993. Load zuint to read it exactly, or use `lossy = "character"` for its exact text, or `lossy = "allow"` to accept the loss.
DBI::dbClearResult(res)
```

With `lossy = "character"` the key arrives as its exact text, and
[`arrow_array()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
turns that text back into the same `int64`.

``` r

out <- fetch_arrow(con, sql)
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

small <- "SELECT 42::BIGINT AS key, DATE '2026-10-21' AS day"
res <- DBI::dbSendQuery(con, small, arrow = TRUE)
stream <- nanoarrow::as_nanoarrow_array_stream(
  duckdb::duckdb_fetch_record_batch(res)
)
str(arrow_to_r(stream))
#> 'data.frame':    1 obs. of  2 variables:
#>  $ key: num 42
#>  $ day: Date, format: "2026-10-21"
DBI::dbClearResult(res)
```
