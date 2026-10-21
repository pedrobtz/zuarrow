# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working
with code in this repository.

## What this is

`zuarrow` moves columns between R and the Apache Arrow columnar format:
the C Data Interface in memory and the IPC stream and file formats on
disk. It converts every Arrow type in the 1.x format to an R vector and
back, reads and writes both IPC framings with LZ4 and zstd bodies, and
keeps a registry that says which R class is the exact form of which
Arrow type. The rule behind every conversion is **exact or error**: a
value crosses without change or the call raises `zuarrow_lossy_error`
naming the column and the exact target. The default is never `warn` or
`allow`.

The one hard dependency is `zukomp` (`Imports` and `LinkingTo`), which
supplies the IPC codecs. `nanoarrow` and `arrow` are `Suggests` only,
used as test oracles. The package is not a query engine, not Parquet,
not a table object model, not transport (Flight, ADBC, PyCapsule) and
not a replacement for `nanoarrow`: its handles are nanoarrow’s handles,
so a session with both loaded passes objects between them without
conversion.

The specification is
[`.agents/design.md`](https://pedrobtz.github.io/zuarrow/.agents/design.md),
adopted from [RFC
0041](https://github.com/pedrobtz/packages/blob/main/rfcs/started/0041-zuarrow-arrow-columns-exact-or-error.md)
in `pedrobtz/packages`. It outranks this file: `CLAUDE.md` orients, the
design decides. Its §13 decisions are all marked (C), the maintainer’s
to overturn, and its §15 open questions are still open.

## Current state

Scaffolded 2026-10-21 with `create-pkg.sh`; no functionality yet.
`DESCRIPTION` still carries the scaffold’s placeholder title,
description and author, `src/zuarrow.c` holds only the R headers, and
the test suite is the placeholder test. The roadmap in
`.agents/roadmap.md` is the stub `pkg-roadmap` fills; it takes the
package to v0.1.0.

## Stage tracking

Progress toward the next version is tracked as GitHub sub-issues, so the
parent issue shows a progress bar such as “6 of 7”.

- **One parent issue per target version**, titled with the bare version,
  for example `v0.1.0`. `v0.1.0` issue: created by `pkg-roadmap`.
- **One sub-issue per roadmap stage**, titled as the roadmap titles it,
  for example `Stage 3 — R interface`, and linking to that section. The
  number of stages is whatever the roadmap has; there is no fixed scale.
- **Every tracking issue carries the `stage` label**, so it can be told
  apart from bug and feature issues and left out of open-issue counts.
- **Close a stage by merging its pull request.** Put `Closes #<n>` in
  the body of the stage’s pull request. Never close a stage whose exit
  criteria are not met; record a deviation in the roadmap first.
- **The roadmap stays authoritative.** The issues record which stages
  are done, not what a stage requires. Adding, removing or renaming a
  stage means editing the roadmap and the sub-issues in the same change.
- **Each stage has a CI tier, `quick` or `full`.** The roadmap sets it,
  and `quick` is the default. See Continuous integration for what each
  means. The second-to-last stage, `Full CI`, runs the full set and
  fixes what it finds before `v0.1.0 readiness`.
- Close the parent issue when CRAN accepts the version and it is tagged.
  Opening a parent issue implies at least one stage sub-issue; a parent
  with no sub-issues shows no progress on the board.

## Versioning

A new package develops at `0.0.0.9000` and targets `0.1.0` for its first
CRAN release. Set `Version: 0.1.0` and the matching `NEWS.md` heading
when the package enters `Pre-flight`. Bump to `0.1.0.9000` only after
CRAN accepts it, never before: a `.9000` version above an unreleased
`0.1.0` heading is wrong.

Until the first release the R API may change freely. Sibling packages
can still depend on this one before CRAN does, through `Remotes:` or
`LinkingTo:`. The design (§3) names `zuint`, `decimal` and `zutempo` as
packages that register exact types with zuarrow at load, and `zuggml`,
`zuflow`, `zutable`, `qio` and `quak` as consumers of its stream
handles. zuarrow itself waits on the `zukomp` release that ships the lz4
and zstd codecs
([zukomp#55](https://github.com/pedrobtz/zukomp/issues/55)); that
release reaches CRAN first and sets the `LinkingTo` floor. A package
that others wait on should reach CRAN first.

## Commands

Run from the package root.

``` sh
Rscript -e 'devtools::load_all()'                # compile src/ and load
Rscript -e 'devtools::document()'                # roxygen -> NAMESPACE, man/
Rscript -e 'devtools::test()'                    # full testthat suite
Rscript -e 'devtools::test(filter = "<name>")'   # one test file
Rscript -e 'devtools::test(shuffle = TRUE)'      # order independence
Rscript -e 'devtools::check()'                   # R CMD check
air format .                                     # format R sources
```

``` sh
tools/update-vendor                              # re-vendor nanoarrow, rewrite PROVENANCE
tools/verify-vendor                              # vendored tree is upstream plus patches
tools/verify-vendor --canary                     # the verifier catches a missing patch
tools/run-benchmarks [--rows N] [--reps R]       # design §10 timings, as Markdown rows
NOT_CRAN=true Rscript -e 'devtools::test(filter = "abi")'   # symbol checks (skip on CRAN)

tools/fetch-fixtures                             # arrow-testing corpus into tests/testthat/fixtures
Rscript tools/make-test-data.R                   # regenerate tests/testthat/data with arrow
```

Oracles 1 and 2 need the `arrow-testing` corpus. Fetch it with
`tools/fetch-fixtures`, or set `ZUARROW_FETCH_FIXTURES=true` and the
tests download it under
[`tempdir()`](https://rdrr.io/r/base/tempfile.html), as CI does; without
either they skip. `tests/testthat/data/` holds small files written by
`arrow` and every input the fuzz target has crashed on, so those tests
run everywhere.

## Architecture

Design §4 names five layers. What exists so far:

- **Vendored nanoarrow** in `src/vendor/nanoarrow/` (see Vendored native
  code).

- **Handles** in `src/zar_xptr.c`: owning external pointers in
  nanoarrow’s `r.h` layout, readers that accept any producer’s handles,
  the schema copy, printing, metadata, and the *spec* round trip. A spec
  is the R list
  `list(format, name, flags, metadata, children, dictionary)` that
  `R/handles.R` builds schemas from (`zar_c_schema_from_spec`) and reads
  them back into (`zar_c_schema_to_spec`).

- **Validation and comparison** in `src/zar_validate.c`, plus a strict
  UTF-8 pass in `src/zar_utf8.c`, which nanoarrow’s full level lacks.

- **Internal constructors** in `src/zar_build.c`: arrays from raw
  buffers, built without validation so tests can make malformed arrays,
  and a stream over arrays. Tests reach them through `helper-arrays.R`.

- **Conversion** in `src/zar_to_r.c` (Arrow to R) and `src/zar_from_r.c`
  (R to Arrow). `zar_c_to_r` takes every batch at once: a plan per
  column picks the R form from the type and the lossy policy, a value
  scan settles the columns whose exactness depends on their values
  (`int64` past 2^53, `int32` `INT_MIN`, a NUL in a string), and each
  column is then allocated once and filled from every batch.
  `R/convert.R` builds the data frame and raises the lossy conditions,
  naming the family package from `zar_exact_target()`.

- **Nested conversion.** A plan is a tree that mirrors the schema. A
  `zar_slice` reads a node’s elements in one batch, either directly or
  through a map (a dictionary’s indices, a run-end encoding’s runs), and
  `up` points at the enclosing struct, whose null rows make its fields
  NA. Factors take the union of every batch’s dictionary through a small
  hash table. Export takes list columns flattened by `zar_prepare()` in
  R, so C never calls R.

- **The registry** lives in `R/registry.R`. Registered columns are
  converted in R: C leaves them (`to` code 9), `zar_c_array_child()`
  lends each batch’s field to the handler, and the pieces are combined
  with [`c()`](https://rdrr.io/r/base/c.html). A `from` handler’s array
  is moved into its slot only after the rest is finished, because
  nanoarrow’s finishing walks every child’s `private_data` as its own.

- **The IPC reader** in `src/zar_ipc_read.c` holds the input in memory
  and walks the stream’s messages or the file’s footer blocks over
  nanoarrow’s decoder. Before decoding it verifies each header, checks
  every field node, buffer range, buffer alignment and compression
  prefix against
  [`arrow_limits()`](https://pedrobtz.github.io/zuarrow/reference/arrow_limits.md)
  (`zar_check_record_batch()`), and copies a misaligned pre-0.15 message
  to aligned memory. Its core compiles without R under `ZAR_STANDALONE`
  for `tools/fuzz/harness.c`; `src/zar_codecs.c` is the zukomp adapter
  (a stub when standalone).

- **The IPC writer** in `src/zar_ipc_write.c` encodes through
  `ArrowIpcEncoderEncodeBatch()`, which vendored patch 0013 adds: a
  record batch or a dictionary batch whose buffers go through zuarrow’s
  callback, 8-byte padded with zeros and compressed through zukomp. It
  writes the schema, each dictionary before the batch that first uses
  it, the batches, the end-of-stream marker, and for files the footer.
  `test-write.R` holds the MD5 of a fixed input in each format and
  codec, so a platform whose bytes differ fails.

**C never raises a condition.** An entry point that fails frees what it
owns and returns a `zar_failure`, `list(kind, message)`. The R caller
wraps every [`.Call()`](https://rdrr.io/r/base/CallExternal.html) in
`zar_check()`, which raises `zuarrow_<kind>_error`. Write the
[`.Call()`](https://rdrr.io/r/base/CallExternal.html) literally at the
call site: R CMD check cannot see the registered routine through a
variable.

## Invariants that are easy to break

The design fixes these before any code exists; each has a consequence a
test or CI leg will catch late. Add more as stages establish them.

- **`zukomp` is the only `Imports`** (D2, D5). `nanoarrow` and `arrow`
  stay in `Suggests`; `bit64` and `vctrs` are never imported. Adding a
  dependency is a design change through the RFC, not a `DESCRIPTION`
  edit.
- **Handles use nanoarrow’s `r.h` layout** (D6): `malloc()`ed struct,
  `NULL` `release` means unset, an array’s tag holds its schema, the
  protected field holds what keeps the memory alive. Deviating breaks
  interchange with DuckDB, Polars, ADBC, `arrow` and `nanoarrow`
  objects.
- **Class vectors are `c("zuarrow_<kind>", "nanoarrow_<kind>")`** and S3
  methods are defined on the first class only (D7). A method on the
  `nanoarrow_*` class overwrites nanoarrow’s when both packages are
  loaded.
- **`lossy = "error"` is the default everywhere**, including the
  [`as.data.frame()`](https://rdrr.io/r/base/as.data.frame.html) and
  [`as.vector()`](https://rdrr.io/r/base/vector.html) S3 methods (D4,
  §15 Q4). A registration may make a lossy default exact and never an
  exact default lossy (§6.10).
- **Vendored nanoarrow builds with `NANOARROW_NAMESPACE` set to
  `zuarrow`** and hidden visibility, so the shared object exports
  `R_init_zuarrow` only and no `Arrow*` symbol (§7, §9). Without it,
  loading `nanoarrow` in the same session clashes.
- **Conversion kernels never call back into R** (§4). A column that
  needs a registered handler is left for the R-level dispatch; a kernel
  that calls R can longjmp over heap it owns.
- **Validate before allocating** (§6.7): nothing goes on the R heap for
  an IPC message that fails validation, and every IPC input gets
  nanoarrow’s `full` level. The `arrow-testing` crash corpus is the
  regression set.
- **Little-endian only in v0.1.0** (D13): a big-endian schema is a
  `zuarrow_format_error`, not a silent misread.

## Testing conventions

- **Self-sufficient.** Every test builds its own inputs inside the
  `test_that()` block. No file-scope objects.
- **Self-contained.** Global state goes through `withr::local_*()`,
  randomised input through
  [`withr::local_seed()`](https://withr.r-lib.org/reference/with_seed.html).
  Tests write only under
  [`tempdir()`](https://rdrr.io/r/base/tempfile.html).
- **Assert on condition classes, never message text.** Use
  `expect_error(..., class = "<pkg>_<kind>_error")`. Wording belongs in
  snapshot tests.
- **Order independence.** `devtools::test(shuffle = TRUE)` is part of
  the definition of done.
- **Borrow a conformance suite before writing one.** Mainstream
  implementations in Python, Java, Go or Node usually ship a test
  corpus. Use it as an oracle rather than inventing cases by hand. None
  wired yet. The design (§9) names four oracles:
  `apache/arrow-testing`‘s IPC golden files and crash corpus, fetched at
  a pinned commit into `tests/testthat/fixtures/`, plus `nanoarrow` and
  `arrow` for interchange. The golden files do not cover big-endian
  reading or the codecs’ own correctness.
- **Helpers live in `tests/testthat/helper-*.R`.** None yet.
- **Keep the suite inside the CRAN time budget.** No runtime recorded
  yet.

## Definition of done

`devtools::document()` and `devtools::check()` clean, meaning 0 errors,
0 warnings and 0 notes. The one allowed note is “New submission” before
the first release. `devtools::test(shuffle = TRUE)` green. CI green at
the change’s tier: the quick profile for a `quick` roadmap stage or an
ordinary pull request, the full profile for a `full` stage, `Full CI`,
and every release. A user-facing change also needs a test, roxygen
documentation and a `NEWS.md` entry.

## Releasing to CRAN

- **CI is the pre-submission check.** The `pedrobtz/r-actions` R CMD
  check runs `--as-cran` on the CRAN-like runners and containers, and it
  replaces win-builder, the macOS builder and R-hub. None of them is a
  release step, and `cran-comments.md` lists the CI legs as its test
  environments.
- **Entering `Pre-flight`.** The roadmap’s feature stages are done, the
  version is set as in Versioning, `NEWS.md` and `cran-comments.md` are
  written, and CI is green. Only submission work remains.
- **Before submitting,** run `pkg-critical-review` once the roadmap is
  implemented and fix what it files, then `pkg-cran-review`, and resolve
  every finding. Both skills are in `pedrobtz/r-skills`.
- **The pretest is automated and does not read `cran-comments.md`.** A
  NOTE that is explained but not fixed gets the upload archived. Fix the
  NOTE, as under Vendored native code, instead of justifying it.
- **After acceptance,** `pkg-post-cran` tags the submitted commit with
  the bare version, `0.1.0` (no `v`), publishes the GitHub release,
  bumps to `0.1.0.9000`, closes the version’s parent issue and moves the
  board card.

## Editing rules

- roxygen comments are the source. Never edit `man/` or `NAMESPACE` by
  hand.
- Edit `README.Rmd`, not the generated `README.md`.
- Keep prose simple and short. One idea per sentence.
- Wrap roxygen text at 80 characters and run `air format .` on R
  sources.
- Use `lower_snake_case`, and prefix internal native symbols with `zar_`
  (`ZAR_` for macros), the prefix the design fixes in §3.
- Keep hard runtime dependencies at zero unless a recorded design
  decision says otherwise. Here D2 records `zukomp`.
- Export and document public functions. Do not create roxygen topics for
  internal ones.

## Continuous integration

Workflows come from `pedrobtz/r-actions`. Call those reusable workflows
instead of writing bespoke ones, and pin a released tag rather than
`main`. Pin a workflow that holds a write token, such as `coverage.yml`,
to a commit, with the tag in a comment. The `R-CMD-check` workflow must
call `r-cmd-check.yml`, because a hand-rolled one does not count as the
pre-submission check. This package calls `r-cmd-check.yml@v1` from
`.github/workflows/R-CMD-check.yaml` and `coverage.yml@v1` from
`.github/workflows/coverage.yaml`; `.github/workflows/pkgdown.yaml` is
the `r-lib/actions` pkgdown workflow.

Small edits get a small run. The shared workflows look at the files a
pull request changes, compared with its merge base:

- **Markdown only**, such as `README.md`, `NEWS.md` or
  `cran-comments.md`, skips every check. Only coverage and the pkgdown
  site run.
- **`DESCRIPTION` or `README.Rmd` as well**, and nothing else, adds one
  R CMD check on Ubuntu R-release.
- **Any other file** runs everything.

So put a README or `DESCRIPTION` touch-up in its own pull request. Once
a pull request changes code, every later push to it runs every workflow.

### Quick by default, full by exception

The full profile is slow. gctorture at step 20 alone has taken 36 to 107
minutes on sibling packages. Waiting on it between roadmap stages was
the main thing slowing roadmaps down, so:

- **Pull requests run the quick profile.** It should finish in under
  five minutes. If it doesn’t, raise gctorture’s `quick-step` or trim
  `quick-containers` in the caller workflows; never cut the full
  profile.
- **A `full` roadmap stage takes the `full-ci` label** and merges only
  on a green full run. The roadmap gives the reason in the stage’s
  `**CI.**` line, for example first compiled code, a `PROTECT` or
  finalizer change, a vendored library, or a Windows-only path.
- **Don’t wait on the full run a merge starts** on the default branch,
  and cancel older full runs it supersedes. A failure that only the full
  set shows goes on the `Full CI` stage issue as a comment with the run
  link, and is fixed there. A failure the quick profile also shows is
  fixed now.
- **`Full CI` and `v0.1.0 readiness` wait** for a green full run on
  their merge commit, and the release commit always needs one.
- Locally, run `gctorture(TRUE)` on the code a C change touches when it
  is cheap; the full run is the authority.

## Vendored native code

The nanoarrow C library’s core and ipc components, Apache-2.0, release
`apache-arrow-nanoarrow-0.9.0` (commit `9fad802`), live under
`src/vendor/nanoarrow/` (design §7, D1), with the flatcc runtime
nanoarrow bundles. `src/vendor/PROVENANCE` holds the tag, commit,
archive SHA-512, the SHA-256 of every file and the patch list;
`inst/COPYRIGHTS` and `LICENSE.note` carry the notices, including three
MIT and one BSD flatcc header. Its integration-testing header goes into
the test harness only, never into `zuarrow.so` (D18). lz4 and zstd are
not vendored; they come from `zukomp` (D2).

- **The tree is derived, never edited.** `tools/derive-vendor` downloads
  the release, checks the SHA-512 Apache publishes, runs upstream’s
  `ci/scripts/bundle.py --symbol-namespace=zuarrow --with-ipc --with-flatcc`,
  splits the generated FlatBuffers code into
  `nanoarrow_ipc_flatcc_generated.h` and applies `tools/patches/` in
  order. `tools/update-vendor` writes the tree and `PROVENANCE`;
  `tools/verify-vendor` re-derives and fails on any byte of difference,
  and `--canary` proves it would catch a missing patch.

- **Patches.** `0001-no-suppressing-pragmas` removes flatcc’s
  `#pragma diagnostic ignored` lines (a NOTE); `0002-unused-locals`
  fixes the two generated macros whose unused locals `-Wall` then
  reports (R CMD check counts “warning: unused” as significant). Every
  patched file carries a “Modified for the zuarrow R package” notice.

- **Visibility.** `src/Makevars` defines `NANOARROW_DLL` empty, because
  nanoarrow otherwise marks its API `visibility("default")` and hidden
  visibility would not hide it. `src/zuarrow-win.def` exports
  `R_init_zuarrow` alone on Windows. `test-abi.R` checks both, and that
  nothing CRAN’s compiled-code check reports is referenced.

- Pin a stable upstream release, never `master` or a release candidate.

- Record the tag, the commit and the checksums, and write down the
  update procedure so the next bump is mechanical.

- Keep upstream `LICENSE` and `NOTICE` under `src/vendor/<lib>/`,
  declare the vendored code in `DESCRIPTION` and `inst/COPYRIGHTS`.

- Keep the vendor tree clearly separated from first-party source, and
  record every local patch and why it exists.

- **CRAN’s compiled-code check applies to vendored code too.** No
  `stdout` or `stderr`, no `printf`, `abort`, `exit` or system RNG may
  be linked, even behind a debug switch that never runs. Remove them
  with a patch in `tools/patches/`, list it in `src/vendor/PROVENANCE`,
  and make the vendor-verify script check “upstream plus exactly these
  patches”. Avoid diagnostic-suppressing pragmas too, because they draw
  their own NOTE. zuhtml is the reference:
  `tools/patches/0002-no-stdio.patch` and `tools/verify-vendor`. zuxml’s
  first upload was archived because it justified such a symbol instead
  of patching it.

- Guard against regressions in CI: run `nm -u` on the built objects and
  fail on any of those symbols, so an upstream bump cannot bring them
  back.

## Commits and pull requests

Short, imperative, sentence-case commit subjects, optionally scoped.
Keep each commit focused and do not sweep in unrelated files. A pull
request explains the user-visible outcome and the rationale, links
related issues, lists the checks that were run and the tests that were
skipped, and flags platform-sensitive or vendored changes. Performance
claims need evidence.

Never commit or push to the default branch. Work on a branch, open a
pull request, and leave it for review. Do not merge a pull request
unless you are told to.

When you find a defect, in this package or in an upstream tool, open an
issue for it rather than only working around it.

## Working with skills

The portfolio’s workflow skills live in `pedrobtz/r-skills` (`pkg-init`,
`pkg-roadmap`, `pkg-implement`, `pkg-critical-review`,
`pkg-cran-review`, `pkg-post-cran`, `pkg-readme`); the general process
skills are [Superpowers](https://github.com/obra/superpowers).
`building-a-package.md` in `pedrobtz/packages` walks through them in
order. Both sets defer to this file where they overlap, so the
settlements are recorded here.

- **One design.** The specification is `.agents/design.md`, adopted from
  the package’s RFC in `pedrobtz/packages/rfcs`. A package with an
  adopted design is past `brainstorming`; a design change goes through
  the RFC, not a new spec. Superpowers’ default
  `docs/superpowers/specs/` is not used.
- **Plans at two levels.** `.agents/roadmap.md` holds the stages, one
  mergeable pull request each, with exit criteria and a CI tier
  (`pkg-roadmap`). Inside a stage, `writing-plans` breaks the work into
  tasks of one test cycle each, saved as `.agents/plans/stage-<n>.md`.
  The roadmap stays authoritative; a plan is scratch and is not kept in
  sync.
- **Build and merge.** `pkg-implement` runs the stage loop: branch
  `stage-<n>-<slug>` from the stage issue, implement the plan with
  `test-driven-development`
  (`Rscript -e 'devtools::test(filter = "<name>")'` is the red/green
  command), open the pull request, merge on green at the stage’s CI
  tier. The confirmation the user gives at the start of that loop is the
  “told to merge” that Commits and pull requests requires, so the
  `finishing-a-development-branch` menu is not presented for stage pull
  requests. Any other pull request still waits for review.
- **Failures and claims.** A failing check or test goes through
  `systematic-debugging` before a fix. “Green”, “done” and “ready for
  CRAN” are claimed only after `verification-before-completion`: run the
  command, read the output.
- **Review.** `requesting-code-review` gates tasks inside a stage.
  `pkg-critical-review` reviews the whole package once the roadmap is
  implemented, with Posit’s reviewers, and files issues. CRAN’s reviewer
  email and GitHub review threads go through `receiving-code-review`.
- **Keep scratch out of the tarball.** `R CMD build` reads
  `.Rbuildignore`, not `.gitignore`. It must list `^\.agents$`,
  `^\.superpowers$` (the Superpowers task ledger), `^\.worktrees$` (if
  git worktrees are kept in the package directory; a sibling directory
  avoids the question), `^\.claude$`, `^CLAUDE\.md$`, `^AGENTS\.md$`,
  `^CRAN-SUBMISSION$` and `^cran-comments\.md$`. A stray top-level file
  is a NOTE, and the pretest archives on NOTEs.
