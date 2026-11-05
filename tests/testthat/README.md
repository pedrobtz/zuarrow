# C error branches the suite does not reach

Every error branch in the first-party C sources (`src/zar_*.c`) that a
test can reach has a test asserting its condition class. The branches
below are the exception. Each needs fault injection, or more memory and
time than the suite may take on CRAN. Branches are named by their message
or function, since line numbers drift.

## Allocation failures

`malloc()`, `ArrowBuffer*()`, `ArrowSchemaDeepCopy()` and the other
nanoarrow allocators fail only when memory runs out. Every "cannot
allocate ..." and "... could not be copied" or "could not be allocated"
branch is of this kind, in `zar_from_r.c`, `zar_build.c`, `zar_xptr.c`,
`zar_ipc_read.c`, `zar_ipc_write.c` and `zar_to_r.c`. So is the
`Rf_error()` in the owning handle constructors of `zar_xptr.c`, the one
place outside ALTREP where C raises, because no handle exists yet to
return a failure through.

## Sizes past 32-bit offsets

With an explicit 32-bit schema (`"u"`, `"z"`, `"+l"`), writing more than
2^31 - 1 bytes or values is a `zuarrow_limit_error`: "more than utf8
offsets can address", "more than binary offsets can address" and "more
than list offsets address" in `zar_from_r.c`. Reaching them takes over
2 GiB of data. Inferred string types switch to `large_utf8` first, which
`test-from-r.R` tests by lowering the `zuarrow.utf8_limit` option.

## R's string limit

A single string longer than 2^31 - 1 bytes can't become an R string:
"longer than R's string limit" in `zar_string_bytes()` of `zar_to_r.c`.
Reaching it takes a 2 GiB value.

## Internal consistency checks

"a malformed list column" in `zar_build_list()` guards the shape of what
`zar_prepare()` hands to C. R always builds that list whole.

Two branches of `zar_c_array_decode()` in `zar_xptr.c` guard what its R
caller and nanoarrow have already settled:

- "the array is not dictionary or run-end encoded". R calls the decoder
  only for a field whose handler was found through its encoded values
  (`zar_field_handler()` sets `decode`).
- "a run-end encoding ends before its last row". `ArrowArrayViewSetArray()`
  validates at nanoarrow's default level first, which already rejects a
  last run end short of the array's offset plus length as a
  `zuarrow_format_error`. `test-registry.R` tests that input.

## No interrupt checks

No first-party loop calls `R_CheckUserInterrupt()`. An interrupt longjmps
out of C, over the scratch buffers and half-built arrays the loop owns,
which would leak them or leave a handle half released. Design section 4
keeps every conversion kernel free of calls into R for the same reason.
A long conversion therefore runs to its end. `arrow_stream()`,
`arrow_next()` and `arrow_read(lazy = TRUE)` bound the work of one call
to one batch.
