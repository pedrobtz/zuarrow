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
