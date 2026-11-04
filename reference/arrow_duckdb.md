# Run a DuckDB query and receive the result exactly

`arrow_duckdb()` runs `sql` on a DuckDB connection and returns the
result as a data frame. The rows travel as an Arrow stream, so every
column is converted as
[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
converts it: exactly, or with an error that names the column.

## Usage

``` r
arrow_duckdb(con, sql, to = NULL, lossy = zar_lossy_policies)
```

## Arguments

- con:

  A connection from `DBI::dbConnect(duckdb::duckdb())`.

- sql:

  The query, a single string.

- to:

  `NULL`, or a named list of prototypes, one per column. For an array
  that is not a `struct`, a single prototype.

- lossy:

  What to do with a column R cannot hold exactly.

## Value

A data frame.

## Details

The query runs with DuckDB's `arrow_lossless_conversion` setting on.
Then `HUGEINT` and `UHUGEINT` arrive as the `arrow.opaque` extension
over `fixed_size_binary(16)`, not as a `decimal128(38, 0)` that cannot
be told from a real decimal. Without a registration for them, they pass
through as a list of 16-byte raw vectors that keeps the extension in its
attributes. The setting is put back as it was when the call returns.

A `BIGINT` whose values all lie within ±2^53 becomes a double. A value
beyond that is a `zuarrow_lossy_error` naming 'zuint' under the default
policy, as for any `int64` column. A package that registers exact
classes with
[`arrow_register()`](https://pedrobtz.github.io/zuarrow/reference/arrow_register.md)
makes such columns exact.

It needs the 'DBI', 'duckdb' (1.5.4 or later) and 'nanoarrow' packages.

## See also

[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
for the conversion and its policies.

## Examples

``` r
con <- DBI::dbConnect(duckdb::duckdb())
#> duckdb keeps downloaded extensions and secrets in a temporary directory:
#> ℹ /tmp/RtmpZli7he/duckdb
#> This is removed when the R session ends.
#> • Extensions are re-downloaded each session.
#> • Secrets are lost.
#> ℹ Run duckdb(shared_home = TRUE) (or create ~/.duckdb) to keep them (suitable for most users).
#> ℹ Run duckdb(shared_home = FALSE) to accept the temporary directory (and silence this message).
#> ℹ See ?duckdb_storage for details and alternatives.
arrow_duckdb(con, "SELECT 42::BIGINT AS id, 'a' AS label")
#>   id label
#> 1 42     a

big <- "SELECT 9007199254740993::BIGINT AS id"
try(arrow_duckdb(con, big))
#> Error in arrow_duckdb(con, big) : 
#>   Column `id` (Arrow format `l`) can't be converted to R exactly: row 1 holds 9007199254740993. Load zuint to read it exactly, or use `lossy = "character"` for its exact text, or `lossy = "allow"` to accept the loss.
arrow_duckdb(con, big, lossy = "character")
#>                 id
#> 1 9007199254740993
DBI::dbDisconnect(con, shutdown = TRUE)
```
