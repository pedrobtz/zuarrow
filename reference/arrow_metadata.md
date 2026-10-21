# Schema metadata

`arrow_metadata()` reads the custom metadata of a schema, or of the
schema of an array or stream, as a named character vector. Values that
are not valid UTF-8 or that contain a NUL byte are kept as raw vectors,
and the result is then a named list.

## Usage

``` r
arrow_metadata(x)

arrow_metadata(x) <- value
```

## Arguments

- x:

  A schema, array or stream handle. The replacement form takes a schema
  handle.

- value:

  A named character vector, a named list of strings and raw vectors, or
  `NULL`.

## Value

A named character vector, or a named list when a value is binary. An
empty named character vector when there is no metadata.

## Details

The replacement form returns a copy of the schema with new metadata:
`NULL` removes it.

## Examples

``` r
schema <- arrow_schema("i")
arrow_metadata(schema) <- c(origin = "zuarrow")
arrow_metadata(schema)
#>    origin 
#> "zuarrow" 
```
