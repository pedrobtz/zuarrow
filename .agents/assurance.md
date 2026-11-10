# Assurance

How this package meets `.claude/shared/assurance.md`. CI checks this
file (r-actions `assurance.yml`), so keep the headings and table
columns as they are.

- **Statuses:** a cell is a fact, `gap #<issue>` or `n/a: <reason>`.
- Written 2026-11-10 from the code on `main` (`8464d2b`), by reading each
  test's assertions, not the design's promises.

## Kinds

`compiled` `untrusted-input` `spec` `lifecycle` `emits`

## Required checks

`Where` names the workflow file under `.github/workflows/` that runs the
check. Add `(own)` when that workflow is the package's own rather than a
call to r-actions.

| Check         | Status   | Where              |
| ------------- | -------- | ------------------ |
| sanitizers    | done     | native-checks.yaml |
| valgrind      | done     | native-checks.yaml |
| rchk          | done     | native-checks.yaml |
| gctorture     | done     | gctorture.yaml     |
| analyzers     | done     | native-checks.yaml |
| alloc-failure | gap #182   |                    |
| mutation      | gap #183   |                    |
| fuzz          | done     | fuzz.yaml          |
| fuzz-reach    | gap #184   |                    |

`fuzz-reach` is a gap although `fuzz.yaml` calls `fuzz.yml`: the r-actions
`v1` tag it pins has no reach step yet, and the caller sets no
`reach-floor`. `valgrind.yml` takes no `env`, so the oracle and crash
corpus tests skip there (see `native-checks.yaml`); they run under ASan in
`sanitizers` and in `gctorture`.

## Boundaries

One row per boundary the package crosses. An oracle knows the answer:

- a conformance suite or test vectors;
- a reference implementation;
- a round trip;
- equivalent inputs compared;
- the bytes the other side received.

"No crash" is not an oracle.

<!-- markdownlint-disable MD013 -->
| Boundary                                         | Oracle                                                                                                                                                 | Carried by                                                                     |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| IPC stream format, decoding                      | `arrow-testing` golden `.stream` files equal their `.json.gz` (read by `zujson`) and the same case's `.arrow_file`; libarrow decodes them to the same values | tests/testthat/test-oracle-golden.R, tests/testthat/test-ci-arrow.R            |
| IPC file format, decoding                        | the same golden cases as `.arrow_file`, compared with the stream and with libarrow                                                                    | tests/testthat/test-oracle-golden.R, tests/testthat/test-ci-arrow.R            |
| IPC decoding, malformed input                    | the `arrow-testing` crash corpus and every fuzz find, each pinned to its expected condition class in `crash-expected.csv`                               | tests/testthat/test-oracle-crash.R, tests/testthat/test-read.R                 |
| IPC decoding, hostile bytes under the fuzzer     | a failure must name a condition kind; what does decode is compared with nothing (limits, validity, file against stream)                                | gap #185                                                                         |
| LZ4_FRAME and ZSTD bodies, decoding              | golden `2.0.0-compression` cases against their JSON; `arrow::write_ipc_file()` at each compression reads back identical                                 | tests/testthat/test-oracle-golden.R, tests/testthat/test-ci-arrow.R            |
| LZ4_FRAME and ZSTD bodies, encoding              | libarrow reads `arrow_write()` at each codec identical to the input; the bytes are pinned per codec version                                            | tests/testthat/test-ci-arrow.R, tests/testthat/test-write.R                    |
| Dictionary and delta dictionary batches, decoding | golden `4.0.0-shareddict` and dictionary cases against their JSON; hand-built delta streams against the values they encode                            | tests/testthat/test-oracle-golden.R, tests/testthat/test-read-rules.R          |
| Big-endian IPC                                   | every golden `1.0.0-bigendian` case is a `zuarrow_format_error` (refused, D13)                                                                         | tests/testthat/test-oracle-golden.R                                            |
| IPC file and stream, encoding, flat columns      | libarrow and nanoarrow read `arrow_write()` identical to the input: integer, double, string, factor and Date, both framings, every codec                | tests/testthat/test-ci-arrow.R, tests/testthat/test-ci-nanoarrow.R             |
| IPC file and stream, encoding, every other type  | libarrow reading what zuarrow writes for nested, list, binary, POSIXct, difftime, metadata, sliced and multi-batch input (only zuarrow reads these back) | gap #186                                                                         |
| IPC encoding, determinism                        | the MD5 of a fixed input in each framing and codec, the same on every CI leg                                                                           | tests/testthat/test-write.R                                                    |
| Arrow to R conversion                            | golden cases against their JSON; nanoarrow's conversion of the same handle for every built-in type                                                     | tests/testthat/test-oracle-golden.R, tests/testthat/test-ci-interop-types.R    |
| R to Arrow conversion                            | nanoarrow builds every built-in type from the same values and `arrow_equal()` holds; random values with nulls round-trip identically                    | tests/testthat/test-ci-interop-types.R, tests/testthat/test-property.R         |
| C Data Interface, import                         | nanoarrow's, libarrow's and DuckDB's handles convert to the values they hold                                                                           | tests/testthat/test-ci-interop.R, tests/testthat/test-ci-duckdb.R              |
| C Data Interface, export                         | nanoarrow reads zuarrow's schemas, arrays and streams to the same values                                                                               | tests/testthat/test-ci-interop.R, tests/testthat/test-ci-nanoarrow.R           |
| UTF-8 validation                                 | eight hand-written known-answer sequences (overlong, surrogate, above U+10FFFF, truncated)                                                            | tests/testthat/test-validate.R                                                 |
| UTF-8 validation, every byte sequence            | differential against an independent decoder over random and exhaustive short inputs                                                                   | gap #187                                                                         |
<!-- markdownlint-enable MD013 -->

pyarrow is not listed: it is the same libarrow C++ the `arrow` R package
already checks against, so it would add no independent answer.

## Objects

One row per object that outlives the call that made it. "Sequences" is
the test of its out-of-order use (abort then read, use after end, use
after free). The guard columns name the test, or say why the guard
cannot apply.

None of these holds a file descriptor, socket or thread: a path is read
whole and closed when the reader opens, and a connection is read to its
end in R first. So none needs a fork guard: a forked child gets its own
copy of heap memory. Unwind: every owning handle's finalizer
is registered on the line after `R_MakeExternalPtr()` (`zar_xptr.c`), and
the conversion and writer scratch are external pointers with finalizers
(`zar_to_r.c`, `zar_ipc_write.c`), but no test makes an allocation fail.

The deferred vector's owner guard is a bug, not only a missing test
(#181). It checks that the handle has a release callback, not that the
handle still holds the array whose buffers it points into.

<!-- markdownlint-disable MD013 -->
| Object                                                             | Sequences                                                                                                                         | Fork                                         | Unwind | Owner                                                                                                                                         |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| schema handle (`zuarrow_schema`)                                   | tests/testthat/test-handles.R: released, NULL and foreign pointers, use after release                                             | n/a: heap memory only, no OS resource        | gap #182 | its finalizer; tests/testthat/test-handles.R "finalizers release handles without error"                                                       |
| array handle (`zuarrow_array`)                                     | tests/testthat/test-handles.R and test-write.R: released array, array whose schema was released, written then reused              | n/a: heap memory only, no OS resource        | gap #182 | its finalizer; the tag holds the schema                                                                                                       |
| stream over arrays (`arrow_stream()`), and borrowed arrays          | gap #189                                                                                                                            | n/a: heap memory only, no OS resource        | gap #182 | the protected field holds the arrays and each borrowed array's lender (`zar_c_stream_from_arrays()`, `zar_c_array_borrow()`)                  |
| IPC reader stream (`arrow_read(lazy = TRUE)`)                      | gap #188                                                                                                                            | n/a: the input is a heap copy, no descriptor | gap #182 | the reader frees its copy; a raw vector read in place is held in the protected field, for `lazy = FALSE` only (tests/testthat/test-read.R)    |
| chain of reader streams (a list of sources, `lazy = TRUE`)         | gap #188                                                                                                                            | n/a: heap copies only, no descriptor         | gap #182 | the chain owns its readers and refuses one that reads in place (tests/testthat/test-read.R "a chain takes only readers that own their input") |
| deferred string vector (ALTREP, `copy = FALSE`)                    | tests/testthat/test-deferred.R: released array, elements made before release, gc, `saveRDS()`, set in place, data pointer         | n/a: R heap and array handles only           | n/a: holds no native memory; its cache is on the R heap in `data2` | gap #181                                                                                                                                        |
<!-- markdownlint-enable MD013 -->

## Limits

One row per limit the package enforces. "Straddled by" is the test of
`limit - 1`, `limit` and `limit + 1` on every path that reaches it.

<!-- markdownlint-disable MD013 -->
| Limit                                                        | Unit                                                       | Straddled by                                                                         |
| ------------------------------------------------------------ | ---------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `arrow_limits(max_bytes)`                                    | input bytes, every source of one call together             | gap #190                                                                               |
| `arrow_limits(max_message)`                                  | bytes in one message header or body, and a buffer's length prefix | gap #190                                                                        |
| `arrow_limits(max_batch_rows)`                               | rows in one record batch; values in one dictionary         | gap #190                                                                               |
| `arrow_limits(max_depth)`, reader                            | schema nesting levels                                      | gap #190                                                                               |
| `arrow_limits(max_dictionary)`                               | bytes the delta dictionary copies build                    | gap #190                                                                               |
| conversion depth, 64 (`zar_convert()`)                       | schema nesting levels                                      | tests/testthat/test-nested.R at 64 and 65 levels                                     |
| compressed buffer length prefix                              | decoded bytes, exact                                       | tests/testthat/test-read-rules.R: prefixes 3999 and 4001 against 4000, lz4 and zstd |
| `utf8` to `large_utf8` (`zuarrow.utf8_limit`, 2^31 - 1)      | UTF-8 bytes per column                                     | tests/testthat/test-from-r.R, the limit lowered to 5: columns of 5 and 6 bytes      |
| `list` to `large_list` (2^31 - 1)                            | child values per column                                    | gap #191                                                                               |
| explicit 32-bit offsets on export (`u`, `z`, `+l`)           | bytes or child values per batch                            | gap #191                                                                               |
| inferred `binary` (never `large_binary`)                     | bytes per column                                           | gap #191                                                                               |
| R's string and factor limits on import (2^31 - 1)            | bytes per string; levels per factor                        | gap #191                                                                               |
| int64 and uint64 to double                                   | magnitude, 2^53                                            | tests/testthat/test-to-r.R (2^53 exact), tests/testthat/test-lossy.R (2^53 + 1 lossy) |
| integer widths on export                                     | value range per width                                      | tests/testthat/test-from-r.R "export checks every integer width at its limits"       |
| `ZAR_MAX_PREBUILT`, 256                                      | registered columns per batch                               | tests/testthat/test-registry.R at 256 and 257                                        |
| `arrow_write(batch)`, `arrow_stream(batch)`                  | rows per record batch                                      | tests/testthat/test-property.R: batches of 1, 7, 50 and 1000 over 50 rows            |
| connection block, 1 MiB (`zar_connection_block`)             | bytes per `readBin()`                                      | gap #192                                                                               |
| `ZAR_DIRECT_MAX`, 16                                         | validity bitmaps on the direct conversion path             | gap #192                                                                               |
<!-- markdownlint-enable MD013 -->
