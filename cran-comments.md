# cran-comments

## Submission

This is a new submission.

zuarrow converts columns between R and the Apache Arrow format: the C Data
Interface in memory and the IPC stream and file formats on disk. A
conversion is exact or it raises an error; it never rounds silently.

## Test environments

The pre-submission check is the `pedrobtz/r-actions` R CMD check, run with
`--as-cran`:

* GitHub Actions: macOS, Windows and Ubuntu on R-release, Windows on
  R-devel, and Ubuntu on R-oldrel-1.
* R-hub CRAN-like containers on R-devel: `clang23`, `ubuntu-clang` and
  `ubuntu-gcc16`, plus `nosuggests` and `nold`.
* Native checks on R-devel: ASan and UBSan with gcc and clang, valgrind,
  rchk, LTO, `-fanalyzer`, gctorture, and CRAN's `rcnst`, `rlibro` and
  `vnu` checks.

## R CMD check results

0 errors | 0 warnings | 1 note

* New submission.

## Bundled third-party sources

The package bundles the core and IPC components of the Apache Arrow
nanoarrow C library, release 0.9.0 (Apache-2.0), under
`src/vendor/nanoarrow/`, with the flatcc runtime that nanoarrow bundles (three
MIT and one BSD header). The Apache Software Foundation is a copyright
holder in `Authors@R`. `inst/COPYRIGHTS` states the upstream commit, and
`LICENSE.note` carries the notices.

* The tree is derived from the release with upstream's own bundling script.
  `src/vendor/PROVENANCE` records the archive's SHA-512, the SHA-256 of
  every file, and each local patch and its reason.
* nanoarrow is built with its symbol namespace set to `zuarrow` and with
  hidden visibility. The shared object exports `R_init_zuarrow` only, so it
  does not clash with the `nanoarrow` package when both are loaded.
* No vendored code writes to `stdout` or `stderr`, aborts, exits, or uses
  the system RNG.

lz4 and zstd are not bundled; they come from `zukomp` through `LinkingTo`.

* Source tarball: 492 KB, measured 2026-11-04 with `R CMD build`.
* Installed size: 636 KB, of which 388 KB is the shared object.
* Install time from the tarball: 12 s on macOS 15.7 (x86_64, R 4.5.2).

The source tarball contains no object code.

## Suggested packages

`arrow`, `nanoarrow`, `DBI` and `duckdb` are used only as test oracles and by
one example. The tests that need them skip when they are missing, and the
DuckDB tests and example also skip on CRAN.

## Reverse dependencies

None: this is a new package.
