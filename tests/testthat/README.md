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
`zar_ipc_read.c`, `zar_ipc_write.c` and `zar_to_r.c`. So is
`zar_alloc_abort()` in the owning handle constructors of `zar_xptr.c`,
the one place outside ALTREP where C raises, because no handle exists
yet to return a failure through.

The suite has no fault injection. The `alloc-failure` workflow covers
these branches instead: it runs `tools/alloc-exercise.R` under r-actions'
`failmalloc` interposer once per allocation, failing a different one each
time, and fails on a crash or on a condition design section 8 does not
name. A failed allocation is a bare `zuarrow_error`, or a
`zuarrow_limit_error` in the writer (section 6.8). `zar_code_kind()` in
`zar.h` maps `ENOMEM` to the bare class wherever a fixed kind is chosen
(#233). What the suite can reach is a producer that returns `ENOMEM`:
`test_failing_stream(out_of_memory = TRUE)` checks that every consumer
raises a bare `zuarrow_error` for it.

## Sizes past 32-bit offsets

Under an explicit 32-bit schema, the builder in `zar_from_r.c` refuses a
batch whose offsets would pass 2^31 - 1 with a `zuarrow_limit_error`:
"more than utf8 / binary offsets can address" and "more than list
offsets address". Inference switches character and list columns to
`large_utf8` and `large_list` at the same thresholds. Binary never
switches (design section 6.2), and a factor's levels are always `utf8`.

Reaching any of these at its real size takes 2 GiB, or 2^31 child values
for a list, so internal options lower each threshold. They are read in R
and passed to C as `zar_c_from_r()`'s `limits` argument, never above
`INT32_MAX`:

- `zuarrow.utf8_limit`: the `utf8` switch and the `"u"` refusal,
  a factor's levels included;
- `zuarrow.binary_limit`: the `"z"` refusal, inferred or explicit;
- `zuarrow.list_limit`: the `list` switch and the `"+l"` and `"+m"`
  refusals.

`test-offset-limits.R` straddles each at limit - 1, limit and limit + 1
through `arrow_array()`, `arrow_stream()` and `arrow_write()`. It also
reaches the `"u"` and `"z"` refusals at the real 2^31 bytes, with 2048
copies of one 1 MiB element that R shares (the `"u"` case off CRAN).

## R's string limit

A single string longer than 2^31 - 1 bytes can't become an R string:
"longer than R's string limit" in `zar_string_bytes()` of `zar_to_r.c`,
and "dictionary value ... is longer than R's string limit" when a factor's
levels are built. A factor holds at most 2^31 - 1 levels: "the dictionary
has more levels than a factor holds". Reaching these at their real size
takes a 2 GiB value or tens of GiB of distinct values.

Two internal options lower them, passed to C in `zar_c_to_r()`'s
options and never above `INT_MAX`: `zuarrow.string_limit` (bytes per
string) and `zuarrow.factor_limit` (levels per factor).
`test-offset-limits.R` straddles both at limit - 1, limit and limit + 1:
strings as `utf8`, `large_utf8` and `string_view`, copied and deferred,
read from IPC, and as dictionary values; levels in one dictionary, read
from IPC, and in the union of two batches' dictionaries.

## Internal consistency checks

"a malformed list column" in `zar_build_list()` guards the shape of what
`zar_prepare()` hands to C. R always builds that list whole.

These guard what R or nanoarrow has already checked:

- "a registered handler built N values, not M" in `zar_build_prebuilt()`
  of `zar_from_r.c`. `zar_prebuild()` in `R/from-r.R` compares the
  handler's length first and raises the same `zuarrow_registry_error`,
  which `test-registry.R` tests.
- "the vector is shorter than its rows" in `zar_from_r.c`. R passes the
  row count it took from the same vector or data frame.
- "converting %s columns is not supported" in `zar_plan_init()` of
  `zar_to_r.c`. The switch has a case for every type
  `ArrowSchemaViewInit()` returns, and a format it does not know fails
  there first as a `zuarrow_format_error`.
- "a run-end encoded array's run ends stop short" in `zar_value_equal()`
  of `zar_validate.c`. nanoarrow's default validation, which
  `arrow_equal()` runs on both arrays, refuses an array whose last run end
  is below its offset plus length, at every level of nesting.
- "the metadata is malformed" in `zar_metadata_check_keys()` of
  `zar_utf8.c`, both of them. nanoarrow's `ArrowMetadataReaderInit()`
  always succeeds, and `ArrowMetadataReaderRead()` fails only when no keys
  remain, which the loop condition excludes.

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
