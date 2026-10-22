# zuarrow: benchmarks

Design §10's targets, measured by `tools/run-benchmarks`. The targets do not
gate v0.1.0 (D15); the numbers are on record so each later stage can be
compared with the same bar.

## Input

A data frame of 10⁷ rows: four `double`, two `integer`, two `character`
of ten bytes, one `factor` of 100 levels and one `Date`. The strings are
drawn from a pool of 10⁶ distinct values so R's string cache fits an 8 GB
machine; Arrow stores every value's bytes regardless. Each time is the
median of three runs. arrow is run with `options(arrow.use_altrep =
FALSE)`, so it materialises ordinary vectors as zuarrow does (D8) rather
than deferring the copy past the timing.

## Baseline, 2026-10-21 (Stage 1, before any zuarrow code)

Machine: Mac mini, Intel Core i5-8500B at 3.00 GHz, 6 cores, 8 GB, macOS
15.7.9, R 4.5.2. Packages: arrow 25.0.1, nanoarrow 0.9.0, qio 0.1.1.

| Operation | Time | Note |
| --- | --- | --- |
| `arrow::read_feather()`, plain file | 6540 ms | oracle for `arrow_read()`, plain file |
| `arrow::read_feather()`, lz4 file | 5800 ms | oracle for `arrow_read()`, lz4 file |
| `arrow::write_feather()`, plain file | 8239 ms | oracle for `arrow_write()`, plain file |
| `nanoarrow::read_nanoarrow()` + `as.data.frame()`, stream | 3817 ms | oracle for `arrow_read()`, stream |
| `nanoarrow::as_nanoarrow_array()`, 10⁷ strings | 1274 ms | oracle for `arrow_array()`, 10⁷ strings |
| `nanoarrow::convert_array()`, 10⁷ doubles | 18 ms | reference for the 30 ms `arrow_to_r()` target |
| `qio::read_parquet()` | 5853 ms | context: the family's Parquet reader |

The arrow rows are dominated by materialising the two string columns
under memory pressure on this 8 GB machine; they are the bar zuarrow is
measured against on the same machine, not absolute figures.

## Stage 3, 2026-10-21

Same machine and package versions. Conversion only; the IPC rows come
with Stages 5 and 6.

| Operation | Target | Time |
| --- | --- | --- |
| `arrow_to_r()`, 10⁷ doubles | under 30 ms | 27 ms |
| `arrow_array()`, 10⁷ strings | within 2× of nanoarrow's 1247 ms | 1870 ms |
| `arrow_next()` per 65 536-row batch, a double and a string column | under 5 ms | 1.0 ms |

The `arrow_next()` row times two columns, not the ten of the §10 input;
Stage 6 times the full input. Stage 6 fills every row.

## Stage 6, 2026-10-21

Same machine and package versions, the full §10 input. The oracles were
rerun in the same session, so each target is set against its oracle from
that run.

| Operation | Target | Oracle | Time | Met |
| --- | --- | --- | --- | --- |
| `arrow_read()`, plain file | within 1.5× of `read_feather()` | 5716 ms | 7357 ms (1.29×) | yes |
| `arrow_read()`, lz4 file | within 1.5× of `read_feather()` | 5408 ms | 7258 ms (1.34×) | yes |
| `arrow_read()`, stream | within 1.5× of `read_nanoarrow()` | 3691 ms | 6957 ms (1.88×) | no |
| `arrow_write()`, plain file | within 1.5× of `write_feather()` | 8038 ms | 7984 ms (0.99×) | yes |
| `arrow_to_r()`, 10⁷ doubles | under 30 ms | | 14 ms | yes |
| `arrow_array()`, 10⁷ strings | within 2× of nanoarrow | 1247 ms | 2003 ms (1.61×) | yes |
| `arrow_next()` per 65 536-row batch, ten columns | under 5 ms | | 39 ms | no |

**Both misses are R's string creation.** One 65 536-row string column
takes 9 ms of a batch's 13 ms in isolation, and every other column type
takes about 1 ms. The same strings cost 12 ms through `paste0(s, "")`, so
the time is `mkCharLenCE()` and R's string cache, not the kernel.
nanoarrow converts the same column in under 1 ms because it returns an
ALTREP vector and creates the strings on first access. Its stream row
defers the same work past the timing. D8 has zuarrow materialise ordinary
vectors, so meeting these two rows would mean reversing D8. The
benchmark's two string columns under the memory pressure of the 10⁷-row
input take the batch to 39 ms. Tracked in the issue linked from the
roadmap's Stage 6 deviation.

## D8 amended, 2026-10-22: deferred strings

Same machine, package versions and input, with `copy = FALSE` added (D8,
amended at the maintainer's request in #21). The oracles were rerun in
the same session. The change also checks a string slice's bytes as one
range, which speeds up the copying rows too.

| Operation | Target | Oracle | Time | Met |
| --- | --- | --- | --- | --- |
| `arrow_read()`, plain file | within 1.5× of `read_feather()` | 4997 ms | 7874 ms (1.58×) | no |
| `arrow_read()`, lz4 file | within 1.5× of `read_feather()` | 5147 ms | 6967 ms (1.35×) | yes |
| `arrow_read()`, stream | within 1.5× of `read_nanoarrow()` | 2891 ms | 6447 ms (2.23×) | no |
| `arrow_read(copy = FALSE)`, stream | within 1.5× of `read_nanoarrow()` | 2891 ms | 1649 ms (0.57×) | yes |
| `arrow_read(copy = FALSE)`, plain file | none; for comparison | | 1819 ms | |
| `arrow_write()`, plain file | within 1.5× of `write_feather()` | 8240 ms | 7454 ms (0.90×) | yes |
| `arrow_to_r()`, 10⁷ doubles | under 30 ms | | 19 ms | yes |
| `arrow_array()`, 10⁷ strings | within 2× of nanoarrow | 1253 ms | 1899 ms (1.52×) | yes |
| `arrow_next()` per 65 536-row batch, ten columns | under 5 ms | | 33 ms | no |
| `arrow_next(copy = FALSE)`, the same | under 5 ms | | 5 ms | at the limit |

**The deferred rows compare like with like.** nanoarrow also returns
ALTREP character vectors, so `copy = FALSE` is the fair counterpart of
its row, and it reads the stream in 0.57× its time. One deferred batch
of ten columns takes 5 ms at `system.time()`'s 1 ms resolution: at the
target, not under it. The string columns are now under 1 ms each, and
the rest is the eight other columns at about 0.5 ms each.

**The copying plain-file row moved with its oracle.** `read_feather()`
took 4997 ms this run against 5716 ms in Stage 6, and `arrow_read()`
7874 ms against 7357 ms. On this 8 GB machine both swing with memory
pressure from the two 10⁷-row string columns. The copying stream row is
still a miss, for the reason Stage 6 gave: creating 2 × 10⁷ R strings.

Deferring 10⁷ ten-byte strings in `arrow_to_r()` took 719 ms before the
range check and 61 ms after it: the per-element `memchr()` and UTF-8
calls were the cost, not the ALTREP wrapper.

## Per-type conversion against nanoarrow, 2026-10-22

`tools/bench-types` converts one column of each type, 10⁷ elements, with
and without 10% nulls, in a fresh R session per case; the median of five
runs, in nanoseconds per element. arrow builds every input, so both
packages convert the same array handle. To R, both create every R string:
zuarrow copies, and nanoarrow's ALTREP strings are forced. date64,
timestamp and duration use `lossy = "allow"` in zuarrow, the conversion
nanoarrow makes. From R, `arrow_array()` against `as_nanoarrow_array()`.

"Before" is the build of #25. "After" adds the direct paths: one loop over
a typed buffer for every scan and fill whose slice has no dictionary or
run-end map at any level, nulls marked a byte at a time, the validity
bitmap and numeric buffers built from R without a call per element, no
zeroing of buffers written in full, branch-free packing of logicals, and
list columns flattened without an R call per element. Every exactness
and UTF-8 check is kept.

| Direction | Type | Nulls | Before | After | nanoarrow | Ratio after |
| --- | --- | --- | --- | --- | --- | --- |
| to R | int64 | none | 37.3 | 6.7 | 5.5 | 1.22× |
| to R | int32 | 10% | 41.0 | 1.6 | 1.4 | 1.14× |
| to R | int32 | none | 16.8 | 0.9 | 0.8 | 1.12× |
| to R | int64 | 10% | 45.5 | 6.8 | 6.1 | 1.11× |
| to R | binary | 10% | 170.4 | 152.4 | 142.3 | 1.07× |
| to R | uint64 | 10% | 45.8 | 6.7 | 6.3 | 1.06× |
| to R | binary | none | 168.6 | 155.0 | 151.0 | 1.03× |
| to R | date32 | 10% | 24.0 | 6.2 | 6.2 | 1.00× |
| to R | duration_us | none | 21.5 | 6.0 | 6.0 | 1.00× |
| to R | struct | none | 30.2 | 5.8 | 5.9 | 0.98× |
| to R | large_string | none | 139.8 | 108.4 | 112.3 | 0.97× |
| to R | float32 | none | 19.7 | 5.5 | 5.8 | 0.95× |
| to R | struct | 10% | 94.1 | 6.8 | 7.3 | 0.93× |
| to R | float64 | none | 1.5 | 1.3 | 1.4 | 0.93× |
| to R | large_string | 10% | 126.6 | 95.3 | 105.9 | 0.90× |
| to R | duration_us | 10% | 26.2 | 6.1 | 6.8 | 0.90× |
| to R | uint64 | none | 37.7 | 5.8 | 6.5 | 0.89× |
| to R | string | none | 131.3 | 102.7 | 115.3 | 0.89× |
| to R | string | 10% | 124.2 | 95.1 | 106.8 | 0.89× |
| to R | uint32 | 10% | 25.2 | 6.2 | 7.0 | 0.89× |
| to R | float64 | 10% | 20.3 | 1.9 | 2.3 | 0.83× |
| to R | uint32 | none | 21.1 | 4.7 | 5.8 | 0.81× |
| to R | bool | none | 17.4 | 0.4 | 0.5 | 0.80× |
| to R | date64 | 10% | 25.4 | 6.0 | 7.5 | 0.80× |
| to R | float32 | 10% | 24.2 | 5.1 | 6.5 | 0.78× |
| to R | timestamp_us | 10% | 23.7 | 5.2 | 6.9 | 0.75× |
| to R | date32 | none | 19.9 | 4.5 | 6.1 | 0.74× |
| to R | list_int32 | none | 336.5 | 165.0 | 228.0 | 0.72× |
| to R | date64 | none | 20.8 | 4.7 | 6.5 | 0.72× |
| to R | timestamp_us | none | 20.6 | 4.6 | 6.4 | 0.72× |
| to R | list_int32 | 10% | 246.0 | 154.0 | 215.5 | 0.71× |
| to R | bool | 10% | 22.6 | 0.8 | 1.6 | 0.50× |
| to R | int8 | 10% | 21.9 | 0.9 | 2.6 | 0.35× |
| to R | int16 | 10% | 21.1 | 0.9 | 2.6 | 0.35× |
| to R | int16 | none | 16.4 | 0.6 | 1.8 | 0.33× |
| to R | uint8 | 10% | 20.9 | 0.8 | 2.5 | 0.32× |
| to R | int8 | none | 16.3 | 0.5 | 1.8 | 0.28× |
| to R | uint8 | none | 16.5 | 0.5 | 2.0 | 0.25× |
| to R | dictionary | 10% | 23.0 | 10.0 | 52.9 | 0.19× |
| to R | dictionary | none | 18.5 | 8.9 | 53.7 | 0.17× |
| from R | list_integer | none | 2298.5 | 625.5 | 370.0 | 1.69× |
| from R | list_integer | 10% | 2343.0 | 594.5 | 361.0 | 1.65× |
| from R | data.frame | none | 20.8 | 7.9 | 5.4 | 1.46× |
| from R | integer | none | 4.9 | 0.9 | 0.8 | 1.12× |
| from R | character | none | 83.2 | 61.8 | 61.5 | 1.00× |
| from R | character | 10% | 129.6 | 65.0 | 65.1 | 1.00× |
| from R | data.frame | 10% | 138.9 | 11.1 | 13.4 | 0.83× |
| from R | Date | none | 26.5 | 4.1 | 5.7 | 0.72× |
| from R | Date | 10% | 79.3 | 6.8 | 9.5 | 0.72× |
| from R | POSIXct | none | 27.4 | 8.5 | 12.3 | 0.69× |
| from R | POSIXct | 10% | 81.0 | 9.9 | 16.0 | 0.62× |
| from R | double | none | 10.4 | 2.4 | 4.5 | 0.53× |
| from R | integer | 10% | 71.5 | 2.1 | 4.7 | 0.45× |
| from R | double | 10% | 63.3 | 3.6 | 8.4 | 0.43× |
| from R | factor | none | 10.6 | 1.5 | 3.6 | 0.42× |
| from R | factor | 10% | 77.9 | 2.6 | 7.7 | 0.34× |
| from R | logical | 10% | 69.3 | 1.8 | 8.5 | 0.21× |
| from R | logical | none | 19.1 | 0.7 | 3.5 | 0.20× |

slow: before 45, after 0, of 58
faster than nanoarrow after: 44

The cases left above 1.3× are list columns from R, where the work is R's own `lengths()`, `unique()` and `unlist()`, and a two-column data frame, which adds R-level schema inference to two fast columns.
