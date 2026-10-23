# zuarrow: roadmap

Status: draft 2026-10-21. Implements [design.md](design.md).
Target: v0.1.0, the first CRAN release.
Tracking: [v0.1.0 (#1)](https://github.com/pedrobtz/zuarrow/issues/1), with one
sub-issue per stage;
[CRAN-submission (#12)](https://github.com/pedrobtz/zuarrow/issues/12).

Re-planned 2026-10-23 after the joint design review of `zubin`, `zuint` and
`zuarrow` (`zubin-zuint-zuarrow-2026-10-22.md` in `pedrobtz/packages`,
decisions X1 to X8). Stages 0 to 8 were done by then. The review adds Stage
9 (the DuckDB helper and the contract `zuint` registers against), renumbers
readiness to Stage 10 and appends a Review stage. Its edits that would
re-base the conversion kernels on `zubin`'s `column.h`, take half floats
from `zufast` and wrap buffers in `zubin`'s foreign buffer are deferred to
[After 0.1.0](#after-010): the kernels exist and are benchmarked, `zubin` is
not on CRAN, and none of it changes what a user sees. So the release waits
for `zukomp` 0.2.0 only.

The design's §11 plans seven stages. This roadmap has twelve: the portfolio
brackets feature work with `Package identity`, `Full CI` and `v0.1.0
readiness`, and the vendored build is split from package identity so the
first pull request stays small and quick. The design's stage numbers are
given in each stage's **Design.** line. The order is the design's: handle
layout and vendored build before the type table, the type table before IPC.

Two dependencies outside this repository shape the plan:

- **`zukomp` 0.2.0.** The IPC codecs come from the `zukomp` release that
  [zukomp#55](https://github.com/pedrobtz/zukomp/issues/55) tracks. On
  2026-10-21 that issue is open and CRAN has `zukomp` 0.1.0 without `zstd`
  or `lz4-frame`. Stage 5 develops against the `zukomp` development version
  through `Remotes:`; Stage 9 cannot close until `zukomp` 0.2.0 is on CRAN
  and `Remotes:` is gone.
- **`decimal`.** The design's first registry consumer (§11, §12) lands in
  `pedrobtz/decimal`, not here. Stage 4 opens and links that work; Stage 9
  needs it merged.

## Stages

| Stage | Title | CI | Issue | Pull request | Done |
| --- | --- | --- | --- | --- | --- |
| 0 | [Package identity](#stage-0--package-identity) | quick | [#2](https://github.com/pedrobtz/zuarrow/issues/2) | [#14](https://github.com/pedrobtz/zuarrow/pull/14) | 2026-10-21 |
| 1 | [Vendored nanoarrow](#stage-1--vendored-nanoarrow) | full | [#3](https://github.com/pedrobtz/zuarrow/issues/3) | [#15](https://github.com/pedrobtz/zuarrow/pull/15) | 2026-10-21 |
| 2 | [Handles and schema tools](#stage-2--handles-and-schema-tools) | full | [#4](https://github.com/pedrobtz/zuarrow/issues/4) | [#16](https://github.com/pedrobtz/zuarrow/pull/16) | 2026-10-21 |
| 3 | [Type table and conversion](#stage-3--type-table-and-conversion) | quick | [#5](https://github.com/pedrobtz/zuarrow/issues/5) | [#18](https://github.com/pedrobtz/zuarrow/pull/18) | 2026-10-21 |
| 4 | [Nested types, dictionaries, extensions and the registry](#stage-4--nested-types-dictionaries-extensions-and-the-registry) | quick | [#6](https://github.com/pedrobtz/zuarrow/issues/6) | [#19](https://github.com/pedrobtz/zuarrow/pull/19) | 2026-10-21 |
| 5 | [IPC reader](#stage-5--ipc-reader) | full | [#7](https://github.com/pedrobtz/zuarrow/issues/7) | [#20](https://github.com/pedrobtz/zuarrow/pull/20) | 2026-10-21 |
| 6 | [IPC writer and benchmarks](#stage-6--ipc-writer-and-benchmarks) | quick | [#8](https://github.com/pedrobtz/zuarrow/issues/8) | [#22](https://github.com/pedrobtz/zuarrow/pull/22) | 2026-10-21 |
| 7 | [README and article](#stage-7--readme-and-article) | quick | [#9](https://github.com/pedrobtz/zuarrow/issues/9) | [#23](https://github.com/pedrobtz/zuarrow/pull/23) | 2026-10-21 |
| 8 | [Full CI](#stage-8--full-ci) | full | [#10](https://github.com/pedrobtz/zuarrow/issues/10) | [#24](https://github.com/pedrobtz/zuarrow/pull/24), [#26](https://github.com/pedrobtz/zuarrow/pull/26) | |
| 9 | [DuckDB helper and the typed-package contract](#stage-9--duckdb-helper-and-the-typed-package-contract) | full — new Suggests guard and a contract a sibling builds on | [#28](https://github.com/pedrobtz/zuarrow/issues/28) | | |
| 10 | [v0.1.0 readiness](#stage-10--v010-readiness) | full | [#11](https://github.com/pedrobtz/zuarrow/issues/11) | | |
| 11 | [Review](#stage-11--review) | full | [#29](https://github.com/pedrobtz/zuarrow/issues/29) | | |

## Stage 0 — Package identity

**Issue.** [#2](https://github.com/pedrobtz/zuarrow/issues/2), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `quick`. See the CI policy in `CLAUDE.md`.

**Goal.** The repository says what the package is, checks clean on the quick
profile in under five minutes, and the names the design relies on are
verified against the installed ecosystem.

**Work.**

- `DESCRIPTION`: real `Title` and `Description` from design §1; `Authors@R`
  with the maintainer as `aut`, `cre` and `cph`; `Depends: R (>= 4.1)`;
  `Language: en-GB`; `BugReports`; `Version: 0.0.0.9000` unchanged. No
  `Imports` yet: `zukomp` arrives in Stage 5.
- `.github/workflows/R-CMD-check.yaml`: add
  `{"os": "windows-latest", "r": "devel"}` to `runners`, the row CRAN's own
  Windows R-devel check runs and the default matrix lacks.
- `.github/workflows/coverage.yaml`: pin `coverage.yml` to a commit with the
  tag in a comment, as `CLAUDE.md` requires for a write-token workflow.
- Verify the `zar_` / `ZAR_` prefix against the installed `zu*` packages'
  symbols (design §3) and record the result in design §3.
- List every export of `arrow` 25 that begins `arrow_`, record the list and
  the one known mask (`arrow_array()`, D12, §15 Q3) in design §13 D12.
- Replace the placeholder test with a test of `zuarrow_info()`'s shape, or
  drop it; either way no `2 * 2` test survives.
- `.Rbuildignore` holds every entry `CLAUDE.md`'s "Working with skills"
  lists (done by `pkg-init`; confirm). `CLAUDE.md` exists (done).
- Time the quick profile on the pull request. If any check exceeds five
  minutes, raise `quick-step` or trim `quick-containers` and record it here.

**Exit criteria.**

- `R CMD check` passes on the quick r-actions profile with 0 errors, 0
  warnings, 0 notes; every quick check finished in under five minutes.
- `DESCRIPTION` has no scaffold placeholder text.
- The `R-CMD-check` caller lists the Windows R-devel runner row.
- Design §3 records the prefix check and D12 records the `arrow_` list.

**Design.** §1, §3, D12; the identity half of design stage 0.

## Stage 1 — Vendored nanoarrow

**Issue.** [#3](https://github.com/pedrobtz/zuarrow/issues/3), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `full — a vendored library and the first compiled code: every
platform leg must build the tree, and ASan, UBSan, valgrind and rchk run on
it before anything is written against it.`

**Goal.** nanoarrow 0.9.0's core and ipc components compile into
`zuarrow.so` on every CI leg under the `zuarrow` namespace with hidden
symbols, the vendoring is reproducible, and the performance bar of §10 is on
record before any zuarrow code exists.

**Work.**

- `tools/update-vendor`: fetch tag `apache-arrow-nanoarrow-0.9.0`, copy the
  core (`common/`) and ipc (`ipc/`, with the generated FlatBuffers header),
  apply `tools/patches/*` in order, and record tag, commit and checksums in
  `src/vendor/PROVENANCE`. `tools/verify-vendor` checks "upstream plus
  exactly these patches". The patch list is empty in this stage.
- `src/Makevars` and `src/Makevars.win`: `-DNANOARROW_NAMESPACE=zuarrow`,
  hidden visibility through `$(C_VISIBILITY)`, the vendored include path.
  The build is C only; the C++ testing header stays out of `src/` (D18).
- Strip or patch anything CRAN's compiled-code check flags in the vendored
  tree (`stdout`, `stderr`, `printf`, `abort`, `exit`, system RNG), as
  `CLAUDE.md`'s Vendored native code section requires, and add the `nm -u`
  guard to the build so an upstream bump cannot bring them back.
- `inst/COPYRIGHTS` with the Apache-2.0 text, nanoarrow's `NOTICE`, the
  upstream commit; `LICENSE.note`; the Apache Software Foundation as `cph`
  in `Authors@R` (D14).
- `tests/testthat/test-abi.R`: the shared object exports `R_init_zuarrow`
  only, and no symbol named `Arrow*`.
- `tools/run-benchmarks` and `.agents/benchmarks.md`: build the §10 input
  (10⁷ rows, ten columns) and time `arrow::read_feather()`,
  `arrow::write_feather()`, `nanoarrow::read_nanoarrow()` and
  `qio::read_parquet()` on it. Record the machine and package versions.
- Design §4 and §7 say `src/nanoarrow/`; `CLAUDE.md` says
  `src/vendor/<lib>/`. This stage uses `src/vendor/nanoarrow/` and amends
  the design's two mentions, unless the open question below is answered
  the other way.

**Exit criteria.**

- A full-profile r-actions run is green on the pull request and on the
  merge commit, including ASan, UBSan, valgrind, rchk and every platform leg.
- `tools/verify-vendor` passes, and `src/vendor/PROVENANCE` names the tag,
  commit and checksums.
- `test-abi.R` passes on every leg; the `nm -u` guard finds no forbidden
  symbol.
- `inst/COPYRIGHTS` and `Authors@R` carry the Apache Software Foundation.
- `.agents/benchmarks.md` has a baseline number for each oracle row of §10.

**Design.** §7, D1, D14, D18; the vendoring and baseline half of design
stage 0.

## Stage 2 — Handles and schema tools

**Issue.** [#4](https://github.com/pedrobtz/zuarrow/issues/4), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `full — the first first-party external pointers and finalizers, and
the handle layout every later stage rests on: gctorture at the sensitive
step, valgrind and ASan must pass before the type table is built on it.`

**Goal.** zuarrow makes and accepts schema, array and stream handles in
nanoarrow's layout, and exposes the C library's validation, comparison,
metadata and printing from R.

**Work.**

- `src/zar_xptr.c`: external pointers per D6 (`malloc()`ed struct, `NULL`
  `release` means unset, finalizer calls `release`, array tag holds the
  schema, protected field holds dependencies), class vectors per D7, and
  the main-thread rule for streams (§6.1).
- `arrow_schema(x)` from a format string, an R object or any handle;
  `format()` and `print()` through nanoarrow's schema printer (§6.11).
- `arrow_validate()`, `arrow_equal()`, `arrow_metadata()` and
  `arrow_metadata<-` (§6.11); `zuarrow_info()` (§3).
- Condition classes `zuarrow_error`, `zuarrow_handle_error`,
  `zuarrow_format_error` (§8), with a helper so every later condition
  inherits the root.
- Delayed S3 registrations so nanoarrow's `as_nanoarrow_schema()`,
  `as_nanoarrow_array()` and `as_nanoarrow_array_stream()` accept zuarrow
  handles (§3), guarded for a session without `nanoarrow`.
- Oracle 3 for handles: a schema, array and stream made by `nanoarrow` is
  accepted by every function above, and a zuarrow handle is accepted by
  nanoarrow; tests skip when `nanoarrow` is absent.

**Exit criteria.**

- Every §6.1 and §6.11 behaviour has a passing test; conditions are asserted
  by class.
- Oracle 3 handle tests pass where `nanoarrow` is installed, and the suite
  passes on the `nosuggests` leg without it.
- A full-profile r-actions run is green on the pull request and on the
  merge commit.

**Design.** §6.1, §6.11, §8, D6, D7; design stage 1.

## Stage 3 — Type table and conversion

**Issue.** [#5](https://github.com/pedrobtz/zuarrow/issues/5), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `quick`. The kernels are plain allocate-and-fill C over the handles
Stage 2 proved; Stage 5 and `Full CI` run them under the full set.

**Goal.** Every built-in Arrow type of §6.2 converts to an R vector and
back, exactly or with the error the `lossy` policy demands.

**Work.**

- `src/zar_to_r.c` and `src/zar_from_r.c`: one kernel per type family over
  an `ArrowArrayView`, filling a vector allocated once; the reverse building
  buffers from an R vector. Kernels never call back into R (§4).
- `arrow_to_r()`, `arrow_array()`, `arrow_stream()`, `arrow_next()`, and
  the `as.data.frame()` and `as.vector()` S3 methods (§5), returning plain
  base R objects.
- The `lossy` argument with `error`, `character`, `warn` and `allow`
  (§6.3), the one-pass value scan in C, `to` for named columns, and the
  exact character fallback (D16). `bit64`'s `integer64` under `allow` only
  when loaded (D5).
- Null rules in both directions (§6.9), half-float widening, `large_utf8`
  on export past 2³¹ − 1 bytes, `POSIXct` as `timestamp[us]` (D10).
- `arrow_types()` listing the built-in table; `zuarrow_type_error`,
  `zuarrow_lossy_error`, `zuarrow_lossy_warning`.
- Property tests: for every exact type, random values with nulls round trip
  identically, `arrow_equal()` holds, `arrow_validate("full")` passes.

**Exit criteria.**

- Every §6.2, §6.3 and §6.9 behaviour has a passing test; the lossy table's
  rows each raise `zuarrow_lossy_error` by default and convert under
  `allow`.
- Property round trips pass for every built-in exact type.
- `R CMD check` passes on the quick r-actions profile; `devtools::test(shuffle
  = TRUE)` is green.

**Design.** §5, §6.2, §6.3, §6.9, D4, D5, D8, D10, D16; design stage 2.

## Stage 4 — Nested types, dictionaries, extensions and the registry

**Issue.** [#6](https://github.com/pedrobtz/zuarrow/issues/6), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `quick`. Plain R and C over Stage 3's kernels; nothing new in memory
ownership.

**Goal.** Nested, dictionary and extension columns convert both ways, and
the typed packages have a registry to make the lossy rows exact.

**Work.**

- §6.4: `struct` to nested data frame, `list`, `large_list` and the view
  variants to list columns, `fixed_size_list` to a list column or a matrix
  through `to = arrow_matrix()`, `map` to a list of `key`/`value` frames,
  `max_depth` enforced.
- §6.5: `dictionary<index, utf8>` to `factor` with `ordered`; other value
  types decoded; factors exported as `dictionary<int32, utf8>`.
- §6.6: `arrow_extension` and `arrow_extension_metadata` attributes kept and
  restored; `arrow.bool8` built in.
- §6.10: `arrow_register()`, `arrow_unregister()`, `arrow_registry()`;
  dispatch by format string, prefix pattern, extension name and R class;
  `exact` recorded; session-scoped with removal on unload; replacement
  message naming both packages. `zuarrow_registry_error`,
  `zuarrow_dependency_error`.
- A test-only registration fixture that stands in for a typed package, so
  the dispatch is tested here without a `Suggests` on an unreleased sibling.
- Open an issue in `pedrobtz/decimal` for its `decimal128`, `decimal256`
  and `r.decimal` registration (design §3, §11), with the handler contract
  from §6.10, and link it from this stage's issue. Done 2026-10-21:
  [pedrobtz/decimal#24](https://github.com/pedrobtz/decimal/issues/24).
- Recorded 2026-10-21: registered handlers apply to top-level columns and
  the fields of nested data frames, not to the items of a list column. A
  handler gets each batch's field sliced by its parent's offset and
  length, without the parent's null rows applied. `arrow_register()`
  gained `exact = TRUE`, which §6.10 describes and §5's signature omits.

**Exit criteria.**

- Every §6.4, §6.5, §6.6 and §6.10 behaviour has a passing test.
- The `decimal` registration issue exists and is linked from this stage's
  sub-issue.
- `R CMD check` passes on the quick r-actions profile; `devtools::test(shuffle
  = TRUE)` is green.

**Design.** §6.4, §6.5, §6.6, §6.10, D3; design stage 3.

## Stage 5 — IPC reader

**Issue.** [#7](https://github.com/pedrobtz/zuarrow/issues/7), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `full — a decoder of untrusted input, a patched vendored decoder
and the first call into zukomp's C table: ASan, UBSan, valgrind, rchk and
every platform leg, with the crash corpus as the regression set.`

**Goal.** `arrow_read()` reads both IPC framings from a path, raw vector or
connection, validates everything before allocating, decompresses through
`zukomp`, and decodes every little-endian golden case.

**Work.**

- `DESCRIPTION`: `Imports: zukomp`, `LinkingTo: zukomp`, and `Remotes:
  pedrobtz/zukomp` until 0.2.0 is on CRAN. `rchk.yml` ignores `Remotes`, so
  give it the local install input the r-actions README describes.
- `src/zar_codecs.c`: the adapter from nanoarrow's compression hooks to
  `zukomp_get_api()`'s `lz4-frame` and `zstd`, with the 8-byte length prefix
  as expected size, the `-1` sentinel, and `max_output` binding
  (`zuarrow_limit_error`, `zuarrow_codec_error`).
- `src/zar_ipc_read.c`: framing by the first bytes, footer walk for the file
  format, message sequence for the stream, dictionary and delta batches, a
  replacement dictionary in a file as an error, `columns`, `lazy`, the
  validation list of §6.7 before any R allocation, `full` nanoarrow
  validation of every decoded array, and `arrow_limits()`.
- Sources: `fread()` for a path, in-place for a raw vector, R's connection
  API in blocks for a connection, buffering a file-format stream to the end
  under `max_bytes` (`zuarrow_io_error`).
- The decoder patch for run-end-encoded, string-view, binary-view and
  list-view layouts (D17) in `tools/patches/`, listed in `PROVENANCE`,
  with an upstream pull request opened against nanoarrow #833 and #824
  before this stage closes.
- `ZAR_STANDALONE`: layers 3 and 4 compile without R with a codec adapter
  that leaves bodies compressed; a fuzz target under `tools/fuzz/` that runs
  the crash corpus and mutated golden files with sanitizers.
- `tools/fetch-fixtures`: `apache/arrow-testing` at a pinned commit into
  `tests/testthat/fixtures/`, ignored by `.Rbuildignore` and `.gitignore`.
  Tests skip with a message when the directory is absent. In CI the helper
  fetches when the `ZUARROW_FETCH_FIXTURES` environment variable is set,
  passed through `r-cmd-check.yml`'s `env:` input, since the workflow has
  no pre-test hook (see Open questions).
- Oracle 1: for every little-endian golden case, file and stream decode to
  the same value and equal the JSON; lossy cases compared under
  `lossy = "character"` against the JSON text; `cpp-21.0.0`'s run-end and
  view cases decode; the `union` case raises `zuarrow_lossy_error`; the
  big-endian directory raises `zuarrow_format_error` (D13).
- Oracle 2: every crash-corpus case raises `zuarrow_format_error` or
  `zuarrow_limit_error` under sanitizers.

**Exit criteria.**

- Oracles 1 and 2 pass where the fixtures are present, and the suite skips
  cleanly where they are not.
- The fuzz target runs ten minutes clean under sanitizers locally; the
  result is recorded on the stage issue. The one-hour run is Stage 9's.
- The upstream nanoarrow pull request for the layout patch exists and is
  linked from `PROVENANCE`.
- A full-profile r-actions run is green on the pull request and on the
  merge commit, including ASan, UBSan, valgrind and rchk.

Recorded 2026-10-21:

- Oracle 1 uses libarrow, not the JSON files (see Open questions).
- `ZAR_STANDALONE` builds layer 4 only: the reader, its validation and the
  vendored decoder. The conversion kernels are R by nature.
- Apple's clang has no libFuzzer, so the local ten-minute run drove the
  harness with random mutations of the corpus under ASan and UBSan
  (2 427 180 inputs, clean); the coverage-guided campaign is `fuzz.yaml`
  in CI. Getting there found nine defects, fixed in vendored patches 0005
  to 0012 and in the reader, each kept as a
  `tests/testthat/data/crash-*.arrow` regression input.
- `Remotes:` points at zukomp's default branch, where the codecs merged
  in pedrobtz/zukomp#56 on 2026-10-21, until zukomp's release reaches
  CRAN; rchk installs it through `github-packages`.
- The upstream nanoarrow pull request is prepared, not opened: opening it
  is an outward action in an Apache project, left to the maintainer
  (#17).

**Design.** §6.7, §7 (patch), §9 oracles 1 and 2, D2, D13, D17; design
stage 4.

## Stage 6 — IPC writer and benchmarks

**Issue.** [#8](https://github.com/pedrobtz/zuarrow/issues/8), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `quick`. The writer builds on Stage 5's codec adapter and Stage 3's
kernels; byte identity across platforms is observed in `Full CI`.

**Goal.** `arrow_write()` emits both framings deterministically, `arrow`
reads what zuarrow writes and the reverse, and every §10 row has a number.

**Work.**

- `src/zar_ipc_write.c`: batching by `batch` rows, file and stream framing,
  8-byte padding (D11), `compression` with `level` through `zukomp` and the
  `-1` sentinel for buffers that do not shrink, `dictionary` batches for
  factors, schema and field `metadata`, `.arrows` defaulting to the stream
  format, `NULL` target returning a raw vector.
- Determinism: fixed message order, no timestamps, every padding byte
  zeroed, FlatBuffers in a fixed field order. A snapshot of the hash of
  `arrow_write()` on a fixed input, so a leg that differs fails in `Full
  CI`.
- Oracle 4: `arrow::write_feather()` at each compression read by
  `arrow_read()`; `arrow_write()` at each option read by
  `arrow::read_feather()` and `arrow::read_ipc_stream()`; identical frames
  for the exact types. Tests skip when `arrow` is absent.
- `tools/run-benchmarks` gains the zuarrow rows of §10;
  `.agents/benchmarks.md` records a number for every row, met or not (D15).

**Exit criteria.**

- Every §6.8 behaviour has a passing test, and the determinism snapshot
  passes.
- Oracle 4 passes where `arrow` is installed.
- `.agents/benchmarks.md` has a number for every row of §10.
- `R CMD check` passes on the quick r-actions profile; `devtools::test(shuffle
  = TRUE)` is green.

**Design.** §6.8, §9 oracle 4, §10, D9, D11, D15; design stage 5.

**Recorded 2026-10-21.** Every §10 row has a number, as the exit
criterion asks, and two miss their target: `arrow_read()` on the stream
(1.88× of `read_nanoarrow()`) and `arrow_next()` on ten columns (39 ms).
Both are the cost of creating R strings, which nanoarrow defers behind
ALTREP and D8 has zuarrow pay at once. The maintainer decides between
revising the targets and revisiting D8, in
[#21](https://github.com/pedrobtz/zuarrow/issues/21). On 2026-10-22 the
maintainer asked for both methods: D8 is amended so `copy = FALSE` defers
string columns, copying stays the default, and `.agents/benchmarks.md`
records the deferred rows beside the copying ones.

## Stage 7 — README and article

**Issue.** [#9](https://github.com/pedrobtz/zuarrow/issues/9), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `quick`. Documentation only.

**Goal.** A reader can tell from the README what zuarrow does and why
exact-or-error matters, and the article shows the headline use case.

**Work.**

- `README.Rmd` written with `pkg-readme`, rendered to `README.md`.
- The article "Receiving a DuckDB result without rounding" under
  `vignettes/`, built by the pkgdown workflow only (the directory is
  build-ignored), with `duckdb` used conditionally.
- `_pkgdown.yml` reference index grouped by §5's headings.
- `NEWS.md` curated into the user-facing entries for 0.1.0.

**Exit criteria.**

- `README.md` is generated from `README.Rmd` and the pkgdown site builds the
  article on the pull request.
- `urlchecker::url_check()` is clean.
- `R CMD check` passes on the quick r-actions profile.

**Design.** §2's README and article item; the documentation half of design
stage 6.

## Stage 8 — Full CI

**Issue.** [#10](https://github.com/pedrobtz/zuarrow/issues/10), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `full`. Always.

**Goal.** The full r-actions profile is green on the default branch's code
with no new features.

**Work.**

- Run the full profile (`full-ci` label) and fix everything it finds:
  gctorture at the sensitive step, valgrind, ASan, UBSan, rchk, every
  platform leg including Windows R-devel, `nosuggests`, `nold`,
  cran-special.
- Confirm the Stage 6 determinism snapshot matches on the Linux, macOS and
  Windows legs.
- Address any full-only failure a `quick` stage left as a comment on this
  issue.

**Exit criteria.**

- A full-profile r-actions run is green on the pull request and on the
  merge commit.
- The determinism snapshot passes on every leg.

**Recorded 2026-10-22.** #24 merged with only a diagnostic, and the full
run on `main` failed the determinism snapshot on arm64 macOS and on the
valgrind leg, with the same wrong hashes each time. The bytes it printed
differ from the other legs in one place: the double `1e300` of the test
input, four units in the last place apart. R's parser rounds that literal
differently where `long double` is no wider than `double`, so the input,
not zuarrow's output, differed. #26 makes the value `2^1000`, which is
exact everywhere, records the new hashes, removes the diagnostic, and
closes the stage again.

**Design.** §12's `R CMD check --as-cran` and byte-identity criteria.

## Stage 9 — DuckDB helper and the typed-package contract

**Issue.** [#28](https://github.com/pedrobtz/zuarrow/issues/28), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `full — a new Suggests guard (duckdb, DBI) and a registration
contract that zuint's Stage 9 builds on: the nosuggests leg, and the engine
round trip on every platform leg`.

**Goal.** A DuckDB result reaches R without rounding in one call, and the
contract a typed package registers against is written down, tested and
fixed before `zuint` builds on it.

**Work.**

- `arrow_duckdb(con, sql, to = NULL, lossy = "error")`: sets
  `arrow_lossless_conversion` on the connection, fetches through DuckDB's
  Arrow stream export (the route `zuint::zu_duckdb_query()` proved on duckdb
  1.5.4.1) and returns a data frame through `arrow_to_r()` with the
  registry applied. `duckdb` and `DBI` join `Suggests`; the article uses
  the helper instead of its hand-rolled fetch.
- The handler contract (design §6.10): a `to` handler may take a third
  argument, the `lossy` policy, so a registering package applies the
  family rule to its own edges (review X4: a value equal to a sentinel
  errors under `"error"`, reads as `NA` with a warning under `"warn"`).
  Two-argument handlers keep working; arity is checked at registration.
- Precedence, documented in §6.10 and tested: an extension name, then an
  exact format string, then a pattern, which is what `zar_handler_for()`
  already does. The consequence for `d:p,0` is stated (review X5): it
  stays a decimal, no built-in route to `int128`, and `to =
  zuint::int128()` is the opt-in through the class entry.
- §6.2's second table: the `int64` and `uint64` row says exact by value
  within ±2⁵³, which is what the value scan does, instead of calling the
  types lossy outright.
- design.md records the review's decisions with the date: §3 (`zuint`
  registers at load and stays `Suggests`, never `Imports`; `zubin` and
  `zufast` are not dependencies of 0.1.0), §6.2, §6.10, D3 and D5 kept as
  they are, D8 (zero copy goes through `zubin`'s foreign buffer, null-free
  arrays only, column handles keeping the array alive through `prot`),
  §14 (the DuckDB helper leaves it; the `zubin` items join it).
- The quick profile: R-devel legs have no binaries for `duckdb` (`zuint`'s
  Stage 5 saw half-hour builds). Keep the quick profile near five minutes
  by restricting the engine tests to the legs with binaries or by caching;
  record what was done here.

**Exit criteria.**

- Through `arrow_duckdb()`, a `BIGINT` column within ±2⁵³ is a double, one
  beyond it raises `zuarrow_lossy_error` naming `zuint`, and `HUGEINT` and
  `UHUGEINT` arrive as `arrow.opaque` over `fixed_size_binary(16)` and
  pass through as storage with the attribute. With `zuint`'s registration
  installed the same columns are `int64`, `int128` and `uint128`; that
  test skips when `zuint` is absent and `zuint`'s Stage 9 runs it for
  real.
- A three-argument handler receives the policy; a two-argument one still
  converts; the precedence test passes for all three key kinds.
- `R CMD check` passes on the full profile with 0 errors, 0 warnings,
  0 notes, the nosuggests leg included.
- design.md carries the dated edits above.

**Design.** §3, §6.2, §6.10, §13 (D3, D5, D8), §14 of design.md; review
decisions X1 to X6.

## Stage 10 — v0.1.0 readiness

**Issue.** [#11](https://github.com/pedrobtz/zuarrow/issues/11), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1). Renumbered from
Stage 9 on 2026-10-23.

**CI.** `full`. Always.

**Goal.** Only the review and the submission are left.

**Work.**

- `zukomp` 0.2.0 is on CRAN: remove `Remotes:`, set the `LinkingTo` floor to
  that version, and record it in design §16.
- The `decimal` registration is merged and its golden cases decode exactly
  with `decimal` installed (design §12).
- The fuzz target runs one hour clean under `ZAR_STANDALONE` with
  sanitizers; the result is recorded on this issue.
- `Version: 0.1.0` and the matching `NEWS.md` heading.
- `cran-comments.md` listing the r-actions CI legs as test environments.
- `urlchecker::url_check()` and `spelling::spell_check_package()` clean.
- `CLAUDE.md`'s current-state, architecture and invariants sections brought
  up to date with what the stages established.

**Exit criteria.**

- `DESCRIPTION` has no `Remotes:`; `zukomp` is the only `Imports`.
- Every item of design §12 holds and is checked off on this issue.
- A full-profile r-actions run is green on the merge commit.

**Design.** §12; the release half of design stage 6.

## Stage 11 — Review

**Issue.** [#29](https://github.com/pedrobtz/zuarrow/issues/29), sub-issue of
[v0.1.0](https://github.com/pedrobtz/zuarrow/issues/1).

**CI.** `full`. Always.

**Goal.** The release candidate is reviewed twice and only the submission
itself is left.

**Work.**

- Critical review: the `pkg-critical-review` skill over code, tests and
  style. Its blocking and required findings become sub-issues of `v0.1.0`,
  each fixed in a pull request that closes it.
- CRAN review: the `pkg-cran-review` skill, run after those fixes so it
  sees the code that is submitted, every FAIL and WARN resolved.
- `NEWS.md` reflects any user-visible fix.

**Exit criteria.**

- Every blocking and required review issue is closed.
- The `pkg-cran-review` table is clean.
- A full-profile r-actions run is green on the merge commit, which becomes
  the release commit.

**Design.** §12 of design.md.

## After 0.1.0

From design §14, in the order it expects them, plus the three items the
2026-10-23 review hands to `zubin` (its headers are not on CRAN, and none
changes what a user sees, so they wait for the zero-copy work):

- **Conversion over `zubin`'s headers**: the validity, bitmap and byte-swap
  kernels of `zubin/column.h`, and half floats from `zufast` instead of
  `zar_half_to_double()`, through `LinkingTo: zubin, zufast`, once `zubin`
  0.1.0 is on CRAN.
- **Zero copy through `zubin`'s foreign buffer** (`zb_r_extbuf_*`):
  null-free arrays only, the column handle holding the array handle in
  `prot` with a release that does nothing, `zuint`'s ALTREP classes for
  integers and this package's for the rest (review X3, D8).
- **A C table**, triggered by upstream adoption (a `bigint = "zuint"` option
  in the duckdb client needs a C-callable) rather than by a profile.

- **A C table** (`zuarrow_api_v1`) so `zuint`, `zutempo` and `qio` convert
  from C. Waits for the registry's R-level shape to settle in use.
- **Zero-copy views** through `zuint`'s ALTREP classes. v0.1.0 copies once
  so the first release has one memory model (D8).
- **Memory-mapped files**, once zero-copy exists and `zufs` is there to map.
- **`qio` as a producer** and **`zutable` from a stream**: decided in those
  repositories.
- **Writing run-end-encoded, union and view types**: no R source type
  produces them.
- **Arrow's cross-implementation integration hooks**, a **chunked vector
  class**, **parsing the printed type notation**, **big-endian reading**:
  each waits for a consumer.

## Open questions

Design §15's questions, with the stage each blocks, and three the roadmap
adds:

- **Vendor path (Stage 1).** Resolved 2026-10-21: `src/vendor/nanoarrow/`,
  and design §4 and §7 are amended.
- **Fixtures in CI (Stage 5).** Resolved 2026-10-21 as assumed:
  `helper-fixtures.R` downloads the files `tests/testthat/fixtures-files.txt`
  lists, at the pinned commit, when `ZUARROW_FETCH_FIXTURES` is set through
  the `env:` input of the check and sanitizer callers.
- **The JSON oracle's compiler (Stage 5).** D18 compiles nanoarrow's C++
  testing header "into the test harness under `tests/`" and never into
  `zuarrow.so`. How that harness is built at test time without a C++
  toolchain assumption on every leg is undecided: a standalone program
  built by `tools/fetch-fixtures`, or a pre-rendered comparison file
  committed with the fixtures. Decided 2026-10-21, a deviation from D18 for
  the maintainer to confirm: oracle 1 compares each case's file with its
  stream, and both with libarrow's decoding of the same file through the
  same conversion where `arrow` is installed. The testing header is not
  vendored, so no C++ is built anywhere.
- **Q1 (Stage 9, and each later release).** Has `nanoarrow` closed #728,
  #622, #617, #833, #824, bundled codecs or grown an exact-targets
  registry? If all, the package shrinks to the registry and the C table.
- **Q2 (Stage 5).** Union dictionary levels across delta batches in the
  eager reader, or error. The roadmap follows §6.5: union.
- **Q3 (Stage 0 records, Stage 3 decides).** Whether `arrow_array()` may
  mask `arrow::arrow_array()` or should be `arrow_from_r()`. Stage 3
  (2026-10-21) kept the design's `arrow_array()`; the mask is documented
  in D12. The maintainer may still rename it before 0.1.0.
- **Q4 (Stage 3).** Whether `as.data.frame()` takes `lossy = "error"` like
  everything else. The roadmap follows the design: yes, and Stage 3 tests
  it.
- **Q5 (board).** CRAN submission or GitHub release for v0.1.0. The board's
  `CRAN intent` field records it; the roadmap assumes `Planned`.
- **Q6 (Stage 3).** Whether foreign handles get `default` or `minimal`
  validation before conversion, once the cost on a 10⁷-row stream is
  measured. Resolved 2026-10-21: `default`, 7 ms more than `minimal` on
  10⁷ rows (design §15 Q6).
- **The 2026-10-23 review (Stage 9).** Decisions X1 to X8 of
  `zubin-zuint-zuarrow-2026-10-22.md` in `pedrobtz/packages`, taken as
  recommended: `zuint` stays `Suggests` and registers at load (X2),
  builds its vectors from R through `zu_from_storage()` (X3), the sentinel
  edge follows this package's policy (X4), `d:p,0` stays a decimal (X5),
  the DuckDB helper ships in 0.1.0 (X6), schema fidelity is this
  package's, carried by the schema handle at export (X7), and the release
  waits for `zukomp` 0.2.0 only (X8).
