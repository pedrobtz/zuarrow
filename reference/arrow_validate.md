# Validate an array or stream

Runs the 'nanoarrow' C library's validation on an array, or on every
batch of a stream. `"minimal"` checks buffer sizes, `"default"` also
checks offsets and lengths, and `"full"` also reads buffer contents:
offsets that only increase and dictionary indices in range, plus a check
zuarrow adds that every non-null string is valid UTF-8. `"full"` is what
zuarrow applies to every IPC input.

## Usage

``` r
arrow_validate(x, level = c("full", "default", "minimal"))
```

## Arguments

- x:

  An array or stream handle.

- level:

  The validation level.

## Value

`TRUE`, invisibly. An invalid array raises `zuarrow_format_error`, with
the path to the offending child in the message.

## Details

The C data interface records no buffer sizes, so no level can tell that
a buffer is shorter than its array's length implies.

Validating a stream reads it to the end, so the stream is consumed.

## Examples

``` r
schema <- arrow_schema(data.frame(x = 1:3))
arrow_validate(schema)
```
