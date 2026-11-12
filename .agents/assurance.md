# Assurance

How this package meets `.claude/shared/assurance.md`. CI checks this
file (r-actions `assurance.yml`), so keep the headings and table
columns as they are.

- **Statuses:** a cell is a fact, `gap #<issue>` or `n/a: <reason>`.
- Written 2026-11-10 from the code on `main` (`8464d2b`), by reading each
  test's assertions, not the design's promises.
- Updated 2026-11-11 on `main` (`ff3dcba`, no code change since). Every
  row was checked against the consolidated native review
  (`.agents/review.md`, `8cf223d`). Its findings are cited as R1 to R13.

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
| alloc-failure | done | alloc-failure.yaml |
| mutation | done | mutation.yaml |
| fuzz          | done     | fuzz.yaml          |
| fuzz-reach | done | fuzz.yaml |

`fuzz-reach` sets a `reach-floor` of 45%; the nightly run on 2026-11-11 reached 48.1% of the lines in its sources. `valgrind.yml` takes no `env`, so the oracle and crash
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
| IPC decoding, hostile bytes under the fuzzer | every schema and batch that decodes is validated again at the full level with the layout and UTF-8 checks, held to the limits passed in (depth, rows, column and dictionary lengths, buffer bytes), and, without dictionaries, written again by nanoarrow's writer and read back identical | tools/fuzz/harness.c |
| LZ4_FRAME and ZSTD bodies, decoding              | golden `2.0.0-compression` cases against their JSON; `arrow::write_ipc_file()` at each compression reads back identical                                 | tests/testthat/test-oracle-golden.R, tests/testthat/test-ci-arrow.R            |
| LZ4_FRAME and ZSTD bodies, encoding              | libarrow reads `arrow_write()` at each codec identical to the input; the bytes are pinned per codec version                                            | tests/testthat/test-ci-arrow.R, tests/testthat/test-write.R                    |
| Dictionary and delta dictionary batches, decoding | golden `4.0.0-shareddict` and dictionary cases against their JSON; hand-built delta streams against the values they encode                            | tests/testthat/test-oracle-golden.R, tests/testthat/test-read-rules.R          |
| Big-endian IPC                                   | every golden `1.0.0-bigendian` case is a `zuarrow_format_error` (refused, D13)                                                                         | tests/testthat/test-oracle-golden.R                                            |
| IPC file and stream, encoding, flat columns      | libarrow and nanoarrow read `arrow_write()` identical to the input: integer, double, string, factor and Date, both framings, every codec                | tests/testthat/test-ci-arrow.R, tests/testthat/test-ci-nanoarrow.R             |
| IPC file and stream, encoding, every other type | libarrow reads `arrow_write()` of every golden case, of its own table of every type (sliced, zero rows, several batches, changing and nested dictionaries, metadata) and of zuarrow's R columns (POSIXct in zones, difftime, lists, structs, field and extension metadata), both framings, every codec: `ValidateFull()` and `Equals(check_metadata = TRUE)`; zuarrow reads the same bytes back as the input | tests/testthat/test-ci-arrow.R, tests/testthat/test-write.R |
| IPC encoding, determinism                        | the MD5 of a fixed input in each framing and codec, the same on every CI leg                                                                           | tests/testthat/test-write.R                                                    |
| Arrow to R conversion                            | golden cases against their JSON; nanoarrow's conversion of the same handle for every built-in type                                                     | tests/testthat/test-oracle-golden.R, tests/testthat/test-ci-interop-types.R    |
| R to Arrow conversion                            | nanoarrow builds every built-in type from the same values and `arrow_equal()` holds; random values with nulls round-trip identically                    | tests/testthat/test-ci-interop-types.R, tests/testthat/test-property.R         |
| C Data Interface, import                         | nanoarrow's, libarrow's and DuckDB's handles convert to the values they hold                                                                           | tests/testthat/test-ci-interop.R, tests/testthat/test-ci-duckdb.R              |
| C Data Interface, export                         | nanoarrow reads zuarrow's schemas, arrays and streams to the same values                                                                               | tests/testthat/test-ci-interop.R, tests/testthat/test-ci-nanoarrow.R           |
| UTF-8 validation                                 | eight hand-written known-answer sequences (overlong, surrogate, above U+10FFFF, truncated)                                                            | tests/testthat/test-validate.R                                                 |
| UTF-8 validation, every byte sequence | base R's `validUTF8()` over every 1-byte sequence, every 2-byte one with a non-ASCII lead (off CRAN), the 3- and 4-byte edges, each form at every position modulo 8, and 2000 random sequences; Kuhn's UTF-8-test.txt cases with their RFC 3629 verdicts | tests/testthat/test-utf8.R |
| Arrow to R conversion, arrays with an offset     | an array at a random offset converts identical to the slice of the values it was built from, for boolean, integer, double, Date and string (copied and deferred); hand-built sliced arrays, structs included | tests/testthat/test-property.R, tests/testthat/test-sliced.R |
| Arrow to R conversion, several batches           | built-in types: a data frame of every exact type in batches of 1, 7, 50 and 1000 rows converts identical to the input                                  | tests/testthat/test-property.R                                                 |
| Registered conversions (`to` handlers), several batches | five handler shapes (a plain class, a factor, an attribute-carrying class, a data frame from a struct, a three-argument handler) give identical results at batches 1, 2, 3 and 5, top level and inside a struct, compared without `unclass()`; each piece's length is checked against its batch | tests/testthat/test-registry.R |
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
| schema handle (`zuarrow_schema`)                                   | tests/testthat/test-handles.R: released, NULL and foreign pointers, use after release                                             | n/a: heap memory only, no OS resource        | alloc-failure.yaml: every allocation after load failed in turn, 10,515 runs, 0 crashes and 0 wrong classes (run 43176325107, `0813b84`) | its finalizer; tests/testthat/test-handles.R "finalizers release handles without error"                                                       |
| array handle (`zuarrow_array`)                                     | tests/testthat/test-handles.R and test-write.R: released array, array whose schema was released, written then reused              | n/a: heap memory only, no OS resource        | alloc-failure.yaml: every allocation after load failed in turn, 10,515 runs, 0 crashes and 0 wrong classes (run 43176325107, `0813b84`) | its finalizer; the tag holds the schema                                                                                                       |
| stream over arrays (`arrow_stream()`), and borrowed arrays | tests/testthat/test-registry.R, test-ci-nanoarrow.R and test-ci-arrow.R: a batch taken with `get_next()`, moved out with `nanoarrow_pointer_move()` or exported to an arrow reader, read after every R reference is dropped and the heap churned, with and without a registered column, at `batch` equal to and below the rows | n/a: heap memory only, no OS resource | alloc-failure.yaml: every allocation after load failed in turn, 10,515 runs, 0 crashes and 0 wrong classes (run 43176325107, `0813b84`) | a lent column is an owning copy whose release needs no R (`zar_c_array_borrow()`, #204), so a batch outlives its stream on any thread; tests/testthat/test-registry.R "a batch taken from arrow_stream() outlives the stream (#204)" |
| IPC reader stream (`arrow_read(lazy = TRUE)`) | tests/testthat/test-reader-states.R: error then next, to_r and schema (same class, no batch, stream and file, format and limit), end then next and schema, select after the first batch, release mid-stream, moved out of its handle after the input is collected, a random-sequence model | n/a: the input is a heap copy, no descriptor | alloc-failure.yaml: every allocation after load failed in turn, 10,515 runs, 0 crashes and 0 wrong classes (run 43176325107, `0813b84`) | the reader frees its copy; a raw vector read in place is held in the protected field, for `lazy = FALSE` only (tests/testthat/test-read.R) |
| chain of reader streams (a list of sources, `lazy = TRUE`) | tests/testthat/test-reader-states.R: a later source failing at a batch (stays failed, reads nothing after) or at its schema (never returned), batchless sources, end then schema, release mid-chain, moved out of its handle | n/a: heap copies only, no descriptor | alloc-failure.yaml: every allocation after load failed in turn, 10,515 runs, 0 crashes and 0 wrong classes (run 43176325107, `0813b84`) | the chain owns its readers and refuses one that reads in place (tests/testthat/test-read.R "a chain takes only readers that own their input") |
| deferred string vector (ALTREP, `copy = FALSE`)                    | tests/testthat/test-deferred.R: released array, elements made before release, gc, `saveRDS()`, set in place, data pointer; an `NA` set through `Set_elt` and then `No_NA` (#221); a handle released and reused, and an array moved out of its handle (#181)         | n/a: R heap and array handles only           | its buffer shares are owning handles whose finalizers release them, so an unwind leaves them to the collector; its cache is on the R heap in `data2`; alloc-failure.yaml (run 43176325107) | the vector holds its own reference-counted share of the buffers (`zar_array_share()`, #181), so the caller's handle may be released or reused; tests/testthat/test-deferred.R "a handle released and reused does not change the vector (#181)"                                                                                                                                        |
<!-- markdownlint-enable MD013 -->

## Limits

One row per limit the package enforces. "Straddled by" is the test of
`limit - 1`, `limit` and `limit + 1` on every path that reaches it.

<!-- markdownlint-disable MD013 -->
| Limit                                                        | Unit                                                       | Straddled by                                                                         |
| ------------------------------------------------------------ | ---------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `arrow_limits(max_bytes)` | input bytes, every source of one call together | tests/testthat/test-limits.R: size -1/=/+1 over raw, path, `file()`, `rawConnection()`, `list(raw)` and a mixed list summed; stream and file; eager and lazy (on CRAN: raw, path, list) |
| `arrow_limits(max_message)` | bytes in one message header or body, and a buffer's length prefix | tests/testthat/test-limits.R: a body, a stream header, a file footer and an lz4/zstd length prefix, each the largest part, -1/=/+1 on every source; stream and file; eager and lazy |
| `arrow_limits(max_batch_rows)` | rows in one record batch; values in one dictionary | tests/testthat/test-limits.R: record batch rows, dictionary values and delta-extended values, -1/=/+1 on every source; stream and file (deltas: stream); eager and lazy |
| `arrow_limits(max_depth)`, reader | schema nesting levels | tests/testthat/test-limits.R: a 3-level schema at 2, 3 and 4 on every source, stream and file, eager and lazy; tests/testthat/test-read.R: 47, 48, 64 and 65 for list, struct and map (#200) |
| `arrow_limits(max_dictionary)` | bytes the delta dictionary copies build | tests/testthat/test-limits.R: 72 bytes built by two deltas at 71, 72 and 73 on every source, eager and lazy; stream only; counted per source of a list |
| conversion depth, 64 (`zar_convert()`)                       | schema nesting levels                                      | tests/testthat/test-nested.R at 64 and 65 levels                                     |
| compressed buffer length prefix                              | decoded bytes, exact                                       | tests/testthat/test-read-rules.R: prefixes 3999 and 4001 against 4000, lz4 and zstd |
| `utf8` to `large_utf8` (`zuarrow.utf8_limit`, 2^31 - 1)      | UTF-8 bytes per column                                     | tests/testthat/test-from-r.R, the limit lowered to 5: columns of 5 and 6 bytes      |
| `list` to `large_list` (2^31 - 1) | child values per column | tests/testthat/test-offset-limits.R, `zuarrow.list_limit` lowered to 6: 5, 6 and 7 child values; each nesting level measured by itself |
| explicit 32-bit offsets on export (`u`, `z`, `+l`, `+m`) | bytes or child values per batch | tests/testthat/test-offset-limits.R, `zuarrow.utf8_limit`, `zuarrow.binary_limit` and `zuarrow.list_limit` lowered to 6: 5, 6 and 7 bytes or values through `arrow_array()`, `arrow_stream()` and `arrow_write()`, a factor's levels as a dictionary and as strings; `u` and `z` also at the real 2^31 bytes through shared elements (`u` off CRAN) |
| inferred `binary` (never `large_binary`) | bytes per column | tests/testthat/test-offset-limits.R, `zuarrow.binary_limit` lowered to 6: 5, 6 and 7 bytes inferred as `binary`, a `zuarrow_limit_error` at 7, through `arrow_array()` and `arrow_write()`; and at the real 2^31 bytes. Whether binary should switch like `utf8` is a design question open in #191 |
| R's string and factor limits on import (2^31 - 1) | bytes per string; levels per factor | tests/testthat/test-offset-limits.R, `zuarrow.string_limit` lowered to 5: strings of 4, 5 and 6 bytes as `utf8` (one and several per range), `large_utf8`, `string_view`, deferred, read from IPC and as dictionary values; `zuarrow.factor_limit` lowered to 3: 2, 3 and 4 levels in one dictionary, from IPC and as the union of two batches |
| int64 and uint64 to double                                   | magnitude, 2^53                                            | tests/testthat/test-to-r.R (2^53 exact), tests/testthat/test-lossy.R (2^53 + 1 lossy) |
| integer widths on export                                     | value range per width                                      | tests/testthat/test-from-r.R "export checks every integer width at its limits"       |
| `ZAR_MAX_PREBUILT`, 256                                      | registered columns per batch                               | tests/testthat/test-registry.R at 256 and 257                                        |
| `arrow_write(batch)`, `arrow_stream(batch)`                  | rows per record batch                                      | tests/testthat/test-property.R: batches of 1, 7, 50 and 1000 over 50 rows            |
| connection block, 1 MiB (`zar_connection_block`) | bytes per `readBin()` | tests/testthat/test-thresholds.R: 1 MiB -1/=/+1 (and 2 MiB, +1 off CRAN) byte-identical through `file()`, `gzfile()` and `rawConnection()`; IPC streams of 1 MiB -8/=/+8 equal the path read; `max_bytes` at the size and size - 1 |
| `ZAR_DIRECT_MAX`, 16 | validity bitmaps on the direct conversion path | tests/testthat/test-thresholds.R: 1, 15, 16 and 17 bitmaps with int32, double, bool and utf8 leaves against a dictionary leaf read element-wise; an int64 2^53 + 1 hidden by the outermost bitmap, lossy when visible |
<!-- markdownlint-enable MD013 -->
