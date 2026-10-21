# Package index

## Handles

Schemas, arrays and streams in the layout nanoarrow uses, built from R
objects or accepted from any Arrow producer.

- [`arrow_schema()`](https://pedrobtz.github.io/zuarrow/reference/arrow_schema.md)
  : Arrow schemas
- [`arrow_array()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
  [`arrow_stream()`](https://pedrobtz.github.io/zuarrow/reference/arrow_array.md)
  : Build an Arrow array or stream from R

## Back to R

Exact conversion to R vectors and data frames, or an error.

- [`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
  [`arrow_next()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
  : Convert Arrow data to R
- [`arrow_matrix()`](https://pedrobtz.github.io/zuarrow/reference/arrow_matrix.md)
  : Matrices as fixed-size lists

## The IPC formats

The Arrow file and stream formats, plain or compressed.

- [`arrow_read()`](https://pedrobtz.github.io/zuarrow/reference/arrow_read.md)
  : Read the Arrow IPC formats
- [`arrow_write()`](https://pedrobtz.github.io/zuarrow/reference/arrow_write.md)
  : Write the Arrow IPC formats
- [`arrow_limits()`](https://pedrobtz.github.io/zuarrow/reference/arrow_limits.md)
  : Limits on IPC input

## Validation, comparison and metadata

- [`arrow_validate()`](https://pedrobtz.github.io/zuarrow/reference/arrow_validate.md)
  : Validate an array or stream
- [`arrow_equal()`](https://pedrobtz.github.io/zuarrow/reference/arrow_equal.md)
  : Compare two schemas, arrays or streams
- [`arrow_metadata()`](https://pedrobtz.github.io/zuarrow/reference/arrow_metadata.md)
  [`` `arrow_metadata<-`() ``](https://pedrobtz.github.io/zuarrow/reference/arrow_metadata.md)
  : Schema metadata

## The registry

Which R class is the exact form of which Arrow type.

- [`arrow_register()`](https://pedrobtz.github.io/zuarrow/reference/arrow_register.md)
  [`arrow_unregister()`](https://pedrobtz.github.io/zuarrow/reference/arrow_register.md)
  [`arrow_registry()`](https://pedrobtz.github.io/zuarrow/reference/arrow_register.md)
  : Register an exact R type for an Arrow type
- [`arrow_types()`](https://pedrobtz.github.io/zuarrow/reference/arrow_types.md)
  : The built-in type table
- [`zuarrow_info()`](https://pedrobtz.github.io/zuarrow/reference/zuarrow_info.md)
  : Package information
