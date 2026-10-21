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

The `arrow_next()` row (under 5 ms per 65 536-row batch) has no oracle and
is measured once Stage 3 lands. The zuarrow rows are added by the stages
that implement them; Stage 6 fills every row.
