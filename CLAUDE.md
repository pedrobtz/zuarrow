# CLAUDE.md

<!-- markdownlint-disable-next-line MD013 -->
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Shared conventions

The portfolio's shared rules are synced into `.claude/shared/` from
`pedrobtz/packages:claude/shared/`. Never edit them here. Where this file and
a shared file disagree, this file wins for zuarrow.

@.claude/shared/workflow.md
@.claude/shared/r-package.md
@.claude/shared/ci.md
@.claude/shared/native-code.md
@.claude/shared/correctness.md
@.claude/shared/assurance.md

## What this is

`zuarrow` moves columns between R and the Apache Arrow columnar format: the
C Data Interface in memory and the IPC stream and file formats on disk. It
converts every Arrow type in the 1.x format to an R vector and back, reads
and writes both IPC framings with LZ4 and zstd bodies, and keeps a registry
that says which R class is the exact form of which Arrow type. The rule
behind every conversion is **exact or error**: a value crosses without
change or the call raises `zuarrow_lossy_error` naming the column and the
exact target. The default is never `warn` or `allow`.

The one hard dependency is `zukomp` (`Imports` and `LinkingTo`), which
supplies the IPC codecs. `nanoarrow`, `arrow`, `DBI` and `duckdb` are not
dependencies at all, not even `Suggests`: they are test oracles that run
in CI only (see Testing). The package is not a query engine, not Parquet,
not a table object model, not transport (Flight, ADBC, PyCapsule) and not a
replacement for `nanoarrow`: its handles are nanoarrow's handles, so a session with
both loaded passes objects between them without conversion.

The specification is [`.agents/design.md`](.agents/design.md), adopted from
[RFC 0041](https://github.com/pedrobtz/packages/blob/main/rfcs/started/0041-zuarrow-arrow-columns-exact-or-error.md)
in `pedrobtz/packages`. It outranks this file: `CLAUDE.md` orients, the
design decides. Its §13 decisions are all marked (C), the maintainer's to
overturn, and its §15 open questions are still open.

## Current state

Verified 2026-11-09: every stage of `.agents/roadmap.md`, 0 to 11, is
merged and its issue closed, Stage 11 (Review) on 2026-11-05. What remains
is the [CRAN-submission issue (#12)](https://github.com/pedrobtz/zuarrow/issues/12).

The first critical review (2026-10-27, issues labelled `review`) has been
fixed. Stage 10 wanted an upstream nanoarrow pull request for vendored
patch 0004; that was not rechecked on 2026-11-09.

`decimal`'s registration (decimal#24) is optional. It is tested when
`decimal` provides it, and 0.1.0 does not wait for it (design §12).

## Versions and dependents

The current version's parent issue is
[v0.1.0 (#1)](https://github.com/pedrobtz/zuarrow/issues/1); submission is
tracked in [CRAN-submission (#12)](https://github.com/pedrobtz/zuarrow/issues/12).

The design (§3) names `zuint`, `decimal` and `zutempo` as packages that
register exact types with zuarrow at load, and `zuggml`, `zuflow`, `zutable`,
`qio` and `quak` as consumers of its stream handles.

zuarrow itself waits on `zukomp` 0.2.0, the release that ships the lz4 and
zstd codecs ([zukomp#55](https://github.com/pedrobtz/zukomp/issues/55)); that
release reaches CRAN first and sets the `LinkingTo` floor, which can
happen 2026-11-27 at the earliest. Until then, verified 2026-11-09,
`DESCRIPTION` builds on zukomp's development version through
`Remotes: pedrobtz/zukomp`, with `zukomp (> 0.1.0)` in `Imports` and
`LinkingTo`. Once it is on CRAN, the first step of #12 is to remove `Remotes:`
and set `zukomp (>= 0.2.0)`.

Deviations from `.claude/shared/workflow.md`; this file wins for zuarrow:

- **The version stays at `0.0.0.9000` until submission** (decided
  2026-11-05), not `0.1.0` from `Pre-flight`. Setting `0.1.0` is a step of
  #12.
- **No `cran-release.yaml` yet.** `CRAN-SUBMISSION` is still git-ignored,
  and a release is tagged by hand with `pkg-post-cran`: the bare version
  `0.1.0` (no `v`) on the submitted commit, the GitHub release, the bump to
  `0.1.0.9000`, closing #1.

## Commands

Beyond the shared `devtools` commands:

```sh
tools/update-vendor                              # re-vendor nanoarrow, rewrite PROVENANCE
tools/verify-vendor                              # vendored tree is upstream plus patches
tools/verify-vendor --canary                     # the verifier catches a missing patch
tools/run-benchmarks [--rows N] [--reps R]       # design §10 timings, as Markdown rows
tools/bench-types [--rows N] [--reps R]          # per-type conversion against nanoarrow
NOT_CRAN=true Rscript -e 'devtools::test(filter = "abi")'   # symbol checks (skip on CRAN)

tools/fetch-fixtures                             # arrow-testing corpus into tests/testthat/fixtures
Rscript tools/make-test-data.R                   # regenerate tests/testthat/data with arrow
```

Oracles 1 and 2 need the `arrow-testing` corpus. Fetch it with
`tools/fetch-fixtures`, or set `ZUARROW_FETCH_FIXTURES=true` and the tests
download it under `tempdir()`, as CI does; without either they skip.
`tests/testthat/data/` holds small files written by `arrow` and every input
the fuzz target has crashed on, so those tests run everywhere.

## Architecture

Design §4 names five layers. What exists so far:

- **Vendored nanoarrow** in `src/vendor/nanoarrow/` (see Vendored native
  code).
- **Handles** in `src/zar_xptr.c`: owning external pointers in nanoarrow's
  `r.h` layout, readers that accept any producer's handles, the schema
  copy, printing, metadata, and the *spec* round trip. A spec is the R
  list `list(format, name, flags, metadata, children, dictionary)` that
  `R/handles.R` builds schemas from (`zar_c_schema_from_spec`) and reads
  them back into (`zar_c_schema_to_spec`).
- **Validation and comparison** in `src/zar_validate.c`, plus a strict
  UTF-8 pass in `src/zar_utf8.c`, which nanoarrow's full level lacks.
- **Internal constructors** in `src/zar_build.c`: arrays from raw buffers,
  built without validation so tests can make malformed arrays, and a
  stream over arrays. Tests reach them through `helper-arrays.R`.

- **Conversion** in `src/zar_to_r.c` (Arrow to R) and `src/zar_from_r.c`
  (R to Arrow). `zar_c_to_r` takes every batch at once: a plan per column
  picks the R form from the type and the lossy policy, a value scan
  settles the columns whose exactness depends on their values (`int64`
  past 2^53, `int32` `INT_MIN`, a NUL in a string), and each column is
  then allocated once and filled from every batch. `R/to-r.R` builds
  the data frame and raises the lossy conditions, naming the family
  package from `zar_exact_target()`.

- **Nested conversion.** A plan is a tree that mirrors the schema. A
  `zar_slice` reads a node's elements in one batch, either directly or
  through a map (a dictionary's indices, a run-end encoding's runs), and
  `up` points at the enclosing struct, whose null rows make its fields NA.
  Factors take the union of every batch's dictionary through a small hash
  table. Export takes list columns flattened by `zar_prepare()` in R, so
  C never calls R.
- **The registry** lives in `R/registry.R`. Registered columns are
  converted in R: C leaves them (`to` code 9), `zar_c_array_child()` lends
  each batch's field to the handler, and the pieces are combined with
  `c()`. A `from` handler's array is moved into its slot only after the
  rest is finished, because nanoarrow's finishing walks every child's
  `private_data` as its own. A `to` handler takes two arguments, or three
  if it also wants the `lossy` policy. Its arity is checked at
  registration. Keys are tried in a fixed order: an extension name, then
  an exact format string, then a pattern (`zar_handler_for()`).

- **The IPC reader** in `src/zar_ipc_read.c` holds the input in memory
  and walks the stream's messages or the file's footer blocks over
  nanoarrow's decoder. Before decoding it verifies each header, checks
  every field node, buffer range, buffer alignment and compression prefix
  against `arrow_limits()` (`zar_check_record_batch()`), and copies a
  misaligned pre-0.15 message to aligned memory. Its core compiles without
  R under `ZAR_STANDALONE` for `tools/fuzz/harness.c`; `src/zar_codecs.c`
  is the zukomp adapter (a stub when standalone).

- **The IPC writer** in `src/zar_ipc_write.c` encodes through
  `ArrowIpcEncoderEncodeBatch()`, which vendored patch 0013 adds: a record
  batch or a dictionary batch whose buffers go through zuarrow's callback,
  8-byte padded with zeros and compressed through zukomp. It writes the
  schema, each dictionary before the batch that first uses it, the
  batches, the end-of-stream marker, and for files the footer.
  `test-write.R` holds the MD5 of a fixed input in each format and codec,
  so a platform whose bytes differ fails.

- **Deferred strings** in `src/zar_altrep.c`: with `copy = FALSE`,
  `zar_build()` turns a plain string or large_string column into an
  ALTREP `STRSXP` after the same per-value checks the copying fill makes.
  It keeps the batch handles in `data1`, caches each `CHARSXP` in `data2`
  on first access, and drops the handles once every element exists. It
  has no serialization method, so `saveRDS()` writes a plain vector.

**C never raises a condition.** An entry point that fails frees what it
owns and returns a `zar_failure`, `list(kind, message)`. The R caller
wraps every `.Call()` in `zar_check()`, which raises
`zuarrow_<kind>_error`. Write the `.Call()` literally at the call site:
R CMD check cannot see the registered routine through a variable.

## Invariants that are easy to break

The design fixes these before any code exists; each has a consequence a
test or CI leg will catch late. Add more as stages establish them.

- **`zukomp` is the only `Imports`** (D2, D5). `nanoarrow`, `arrow`, `DBI`
  and `duckdb` are in no field of `DESCRIPTION`; `bit64` and `vctrs` are
  never imported. Adding a dependency is a design change through the RFC,
  not a `DESCRIPTION` edit.
- **Handles use nanoarrow's `r.h` layout** (D6): `malloc()`ed struct,
  `NULL` `release` means unset, an array's tag holds its schema, the
  protected field holds what keeps the memory alive. Deviating breaks
  interchange with DuckDB, Polars, ADBC, `arrow` and `nanoarrow` objects.
- **Class vectors are `c("zuarrow_<kind>", "nanoarrow_<kind>")`** and S3
  methods are defined on the first class only (D7). A method on the
  `nanoarrow_*` class overwrites nanoarrow's when both packages are loaded.
- **`lossy = "error"` is the default everywhere**, including the
  `as.data.frame()` and `as.vector()` S3 methods (D4, §15 Q4). A registration
  may make a lossy default exact and never an exact default lossy (§6.10).
- **Vendored nanoarrow builds with `NANOARROW_NAMESPACE` set to `zuarrow`**
  and hidden visibility, so the shared object exports `R_init_zuarrow` only
  and no `Arrow*` symbol (§7, §9). Without it, loading `nanoarrow` in the
  same session clashes.
- **Conversion kernels never call back into R** (§4). A column that needs a
  registered handler is left for the R-level dispatch; a kernel that calls R
  can longjmp over heap it owns.
- **Validate before allocating** (§6.7): nothing goes on the R heap for an
  IPC message that fails validation, and every IPC input gets nanoarrow's
  `full` level. The `arrow-testing` crash corpus is the regression set.
- **Little-endian only in v0.1.0** (D13): a big-endian schema is a
  `zuarrow_format_error`, not a silent misread.
- **Every crash input stays in the corpus.** An input that the fuzz
  target or the crash corpus made fail goes into `tests/testthat/data/`
  with its fix. The fuzzer then uses it as a seed, and the tests pin its
  outcome. A vendored fix is a numbered patch in `tools/patches/`, offered
  upstream.
- **Oracle packages stay out of the tarball.** A test or helper that uses
  `nanoarrow`, `arrow`, `DBI` or `duckdb` goes in a `test-ci-*.R` or
  `helper-ci-*.R` file, which `.Rbuildignore` excludes, and guards with
  `skip_without_oracle()`. Anywhere else, R CMD check reports the use as an
  undeclared dependency. The `oracles` workflow runs those files with
  `ZUARROW_ORACLES=true`, where a missing oracle fails.

## Testing

- **Shuffled runs rewrite snapshots.** `devtools::test(shuffle = TRUE)`
  rewrites `_snaps/*.md` in the order the tests ran even when every snapshot
  matches (r-lib/testthat#2364). Discard a diff that only moves sections,
  `git checkout -- tests/testthat/_snaps`, and never commit one.
- **Conformance oracles.** The design (§9) names four oracles:
  `apache/arrow-testing`'s IPC golden files and crash corpus, fetched at a
  pinned commit into `tests/testthat/fixtures/`, plus `nanoarrow` and
  `arrow` for interchange. The golden files do not cover big-endian reading
  or the codecs' own correctness.
- **Unreachable branches.** `tests/testthat/README.md` records the C error
  branches no test can reach, and why.
- **Runtime.** The whole suite took 15 s on 2026-11-04 with the fixtures
  fetched and every oracle installed: `devtools::test(shuffle = TRUE)`,
  macOS x86_64, R 4.5.2. Under gctorture it runs a sample of the repeated
  loops (`helper-gctorture.R`).

## Editing rules

- Internal native symbols use the `zar_` prefix (`ZAR_` for macros), the
  prefix the design fixes in §3.
- The one hard runtime dependency is `zukomp`, recorded as design D2.

## Continuous integration

This package calls `r-cmd-check.yml@v1` from
`.github/workflows/R-CMD-check.yaml` and `coverage.yml` (pinned to a
commit) from `.github/workflows/coverage.yaml`;
`.github/workflows/pkgdown.yaml` is the `r-lib/actions` pkgdown workflow.
`.github/workflows/native-checks.yaml` calls the sanitizers, valgrind, lto,
rchk, analyzers and cran-special, and `.github/workflows/gctorture.yaml`
calls gctorture. Its own and other callers:

- **`oracles.yaml`** runs the `*-ci-*.R` tests from the source tree on
  Ubuntu with every oracle installed and `ZUARROW_ORACLES=true`. r-actions
  has no workflow that runs tests outside the tarball, hence one of its own.
- **`fuzz.yaml`** fuzzes the IPC reader built without R (`ZAR_STANDALONE`):
  short runs on pull requests, a long run nightly, and a dispatch for the
  hour clean on the release candidate that design §12 wants:
  `gh workflow run fuzz.yaml --ref <branch>`. Its seed commit is kept in
  step with `tests/testthat/fixtures-files.txt`.
- **`vendor.yaml`** re-derives `src/vendor/nanoarrow` with
  `tools/verify-vendor` and fails a pull request that changes the vendored
  files without `src/vendor/PROVENANCE`. **`vendor-upstream.yaml`** checks
  weekly for a new nanoarrow release.

The callers' file names end in `.yaml`, so the full set is dispatched with
`gh workflow run R-CMD-check.yaml --ref main` and
`gh workflow run native-checks.yaml --ref main`; it also runs weekly on
Monday.

### gctorture: wide on every push, step 20 on a schedule

gctorture at step 20 is the most sensitive setting and by far the slowest
job, so its job has GitHub's six-hour limit (`timeout-minutes: 360`). It
does not gate merges. Its own caller, `.github/workflows/gctorture.yaml`,
copied from r-actions' `examples/gctorture.yml`, runs it in two ways:

- **Every push and pull request runs the wide `quick-step` under a 10-minute
  budget** (`test-timeout-minutes`). Past the budget the check fails red.
  Widen the step to get back under it; don't skip tests to fit.
- **Step 20 runs on a schedule**: daily while the roadmap is in active
  development, weekly once the package is released and changes slow down.
  Changing the `cron` line is the switch. A red scheduled run opens an issue
  labelled `gctorture`, and the next green run closes it. That issue is
  fixed like any other defect, before the next stage merges.
- **Dispatch step 20 on the branch before merging** a change to `PROTECT`s,
  finalizers or external-pointer handles, and before `Full CI`,
  `v0.1.0 readiness` and the release commit:
  `gh workflow run gctorture.yaml --ref <branch>`. A green run on that commit
  is the evidence; a nightly run on another commit is not. That run is part
  of the definition of done for such a change.
- **Sample repetition, keep every path.** gctorture finds an unprotected
  `SEXP` by running the path that holds it, not by running it again. Under
  gctorture, loops that repeat one path (fuzz iterations, property cases,
  the same input across versions) run a fixed sample. The caller sets an
  environment variable for it, `ZUARROW_GCTORTURE=true`, and
  `helper-gctorture.R` reads it. Every type, branch and error path still runs.

## Vendored native code

The nanoarrow C library's core and ipc components, Apache-2.0, release
`apache-arrow-nanoarrow-0.9.0` (commit `9fad802`), live under
`src/vendor/nanoarrow/` (design §7, D1), with the flatcc runtime nanoarrow
bundles. `src/vendor/PROVENANCE` holds the tag, commit, archive SHA-512, the
SHA-256 of every file and the patch list; `inst/COPYRIGHTS` and
`LICENSE.note` carry the notices, including three MIT and one BSD flatcc
header. Its integration-testing header goes into the test harness only,
never into `zuarrow.so` (D18). lz4 and zstd are not vendored; they come
from `zukomp` (D2).

- **The tree is derived, never edited.** `tools/derive-vendor` downloads
  the release, checks the SHA-512 Apache publishes, runs upstream's
  `ci/scripts/bundle.py --symbol-namespace=zuarrow --with-ipc
  --with-flatcc`, splits the generated FlatBuffers code into
  `nanoarrow_ipc_flatcc_generated.h` and applies `tools/patches/` in
  order. `tools/update-vendor` writes the tree and `PROVENANCE`;
  `tools/verify-vendor` re-derives and fails on any byte of difference, and
  `--canary` proves it would catch a missing patch.
- **Patches.** `src/vendor/PROVENANCE` lists the series, 0001 to 0016,
  in the order applied. `0001-no-suppressing-pragmas` removes flatcc's
  `#pragma diagnostic ignored` lines (a NOTE); `0002-unused-locals` fixes the two
  generated macros whose unused locals `-Wall` then reports (R CMD check
  counts "warning: unused" as significant). Every patched file carries a
  "Modified for the zuarrow R package" notice.
- **Visibility.** `src/Makevars` defines `NANOARROW_DLL` empty, because
  nanoarrow otherwise marks its API `visibility("default")` and hidden
  visibility would not hide it. `src/zuarrow-win.def` exports
  `R_init_zuarrow` alone on Windows. `test-abi.R` checks both, and that
  nothing CRAN's compiled-code check reports is referenced.
