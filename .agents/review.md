# zuarrow native review — consolidated findings

Consolidated on 2026-11-11 from three agent reviews of `main` at `eb20d91`:

| Tag | Reviewer | Scope |
| --- | --- | --- |
| **V** | Vibe | correctness: C boundary, patches, build, R layer |
| **G** | Vibe, GLM pass | same scope, second pass |
| **C** | Codex | vendoring, build, IPC patches, ownership, tests |

Each finding lists the IDs it had in the source reviews (`V:M1`, `G:G1`,
`C:#1`). "Reproduced" means at least one reviewer ran the trigger.
`:::` means the path needs `zuarrow:::zar_c_*`; "exported" means it is
reachable through `arrow_read()`, `arrow_array()`, `arrow_to_r()`,
`arrow_stream()` or the registry.

All reviewers found the suite green (2661 assertions without fixtures,
3520 with `ZUARROW_FETCH_FIXTURES=true`, one decimal-registration skip) and
`tools/verify-vendor` passing. The findings below are what the suite misses.

## Summary

| # | Finding | Severity | Reach | Status | Sources |
| --- | --- | --- | --- | --- | --- |
| R1 | Empty delta dictionary reads past offsets (patch 0015) | memory-safety | exported (hostile IPC) | reproduced (ASan) | V:M9 G:G10 C:#1 |
| R2 | Stream batches don't own borrowed buffers | memory-safety (UAF) | exported (registry + stream) | lifetime defect reproduced | V:M5 G:G6 C:#2 |
| R3 | `zar_c_array_slice` NULL deref / OOB on unvalidated buffers | crash | exported (registry batching) + `:::` | reproduced | V:M2 G:G2 |
| R4 | `zar_c_from_r` unvalidated `start`/`n` | crash / OOB read | `:::` | reproduced (abort) | V:M1 G:G1 |
| R5 | Forged `zuarrow_limits` read past its vector | OOB read | exported | reproduced | V:M4 G:G4 |
| R6 | Nested dictionaries written in dependency-invalid order | wrong-result | exported | reproduced | V:M10 G:G11 C:#3 |
| R7 | ALTREP `No_NA` stale after native `Set_elt` | wrong-result | native mutation only | reproduced | G:G7 C:#4 |
| R8 | `zar_build_list` trusts `zar_list_prep` offsets | OOB read | `:::` | reproduced | V:M3 G:G3 |
| R9 | Fixed-position reads of `opts`/`to`/`columns` | OOB read | `:::` | by inspection, spot-checked | V:M8 G:G5 |
| R10 | `int` truncation of row counts (row names, matrix) | heap overflow / wrong-result | >2^31 rows | by inspection | V:M6 G:G8 |
| R11 | Factor level count checked after codes are written | wrong-result | >2^31 levels | by inspection | V:M7 G:G9 |
| R12 | Makevars objects carry no header dependencies | build | dev builds | reproduced | G:G12 C:#5 |
| R13 | Registry handler pieces combined with `c()` drop classes | robustness | exported | by inspection | G:G13 |

Release blockers, by consensus of the rankings: R1, R2, R3, R4. R5 and R6
follow closely (both exported).

---

## Memory safety and crashes

### R1 — patch 0015: zero-row delta dictionary reads past its offsets buffer
- **Sources:** V:M9, G:G10, C:#1 (P1).
- **Location:** `src/vendor/nanoarrow/nanoarrow_ipc.c:583, 588, 593-594`
  (`ArrowIpcDictionaryOffset(view, 0, …)` and `(view, view->length, …)` in
  `ArrowIpcDictionaryAppendBinary`), from
  `tools/patches/0015-dictionary-delta-concat.patch`.
- **Trigger (reproduced under ASan/UBSan):** an IPC stream with a nonempty
  utf8 dictionary, then a zero-row delta whose offsets buffer is empty, then
  a record batch and EOS. Codex built the input from the repo's own helpers:
  ```r
  devtools::load_all(".", quiet = TRUE)
  source("tests/testthat/helper-arrays.R"); source("tests/testthat/helper-read.R")
  source("tests/testthat/helper-ipc.R")
  b <- factor_stream(c("a", "b")); m <- ipc_messages(b)
  d <- ipc_buffers_dictionary(0, 0, list(c(0, 0)), list(NULL, NULL, NULL), TRUE)
  x <- c(ipc_message_bytes(b, m[[1]]), ipc_message_bytes(b, m[[2]]), d,
         ipc_message_bytes(b, m[[3]]), ipc_eos())
  ```
  Write `x` with `writeBin()`, then run it through a standalone ASan build of
  the fuzz harness, from the package root. `driver.c` is a ten-line `main()`
  that reads the file and calls `LLVMFuzzerTestOneInput()`:
  ```sh
  clang -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
    -DZAR_STANDALONE -DNANOARROW_NAMESPACE=zuarrow -DNANOARROW_DLL= \
    -DFLATCC_NO_ASSERT -Isrc -Isrc/vendor/nanoarrow \
    driver.c tools/fuzz/harness.c \
    src/zar_ipc_read.c src/zar_utf8.c src/zar_codecs.c \
    src/vendor/nanoarrow/nanoarrow.c src/vendor/nanoarrow/nanoarrow_ipc.c \
    src/vendor/nanoarrow/flatcc.c -o reader
  ./reader empty-delta.arrows
  ```
  Result: `heap-buffer-overflow … READ of size 4` in
  `ArrowIpcDictionaryOffset`. The production `arrow_read()` silently succeeds.
- **Why:** the function was written for nonempty contributions. Patch 0012
  lets zero-length arrays carry short offsets buffers, and
  `ArrowArrayViewSetArrayMinimal` in `ArrowIpcDictionaryConcat` does not size
  them.
- **Fix:** return OK at once when `view->length == 0`; before any read,
  require `buffer_views[1].size_bytes >= (offset + length + 1) * width`.
- **Tests:** utf8, large_utf8, binary, large_binary; empty deltas before and
  after nonempty dictionaries. Add the input to `tests/testthat/data/` and the
  fuzz corpus (corpus invariant).

### R2 — batches from `zar_c_stream_next` don't own borrowed buffers
- **Sources:** V:M5, G:G6, C:#2 (P1).
- **Location:** `src/zar_xptr.c:637-680` (`zar_c_stream_next`: the returned
  handle's protected field is never set), `src/zar_xptr.c:670-690`
  (`zar_c_array_borrow`: shallow copy, no-op release, `private_data` cleared,
  owner kept only in the R wrapper's protected field),
  `src/zar_from_r.c:1021`, `src/zar_build.c:128-155`
  (`zar_c_stream_from_arrays` moves the structs into the stream).
- **Trigger (lifetime defect reproduced; UAF not dereferenced):**
  ```r
  e <- new.env(); e$finalized <- FALSE
  arrow_register("i", from = function(x) {
    a <- arrow_array(unclass(x)); reg.finalizer(a, function(p) e$finalized <- TRUE); a
  }, class = "review_integer", package = NULL)
  df <- data.frame(id = 1:3); df$v <- structure(c(11L, 22L, 33L), class = "review_integer")
  s <- arrow_stream(df)
  b <- .Call(zuarrow:::zar_c_stream_next, s)
  rm(s, df); gc(); gc()
  e$finalized                                   # TRUE
  .Call(zuarrow:::zar_c_handle_status, b)       # still "live"
  ```
- **Why:** the Arrow C stream interface requires `get_next()` results to
  outlive the stream. Moving the C struct does not move its ownership
  dependency, which lives on R objects reachable only through the stream.
  A foreign consumer that moves the struct out of its R wrapper has the same
  problem.
- **Fix:** carry ownership in `private_data` + `release` (preferred), or give
  the returned handle the stream's protected field, or copy the batch. An
  owning copy is a defensible first fix. Audit child handles and handler
  outputs for the same pattern, including release on another thread.
- **Test gap:** `tests/testthat/test-registry.R:526` keeps the stream alive
  and uses `batch = 3` on a four-row column, so it takes the copied-slice
  path, not the whole-column borrow. Add: extract batch, drop producer, `gc()`,
  consume; and move the C stream out of its wrapper before `gc()`. Confirm
  under ASan.

### R3 — `zar_c_array_slice` NULL deref and OOB copy on unvalidated buffers
- **Sources:** V:M2, G:G2.
- **Location:** `src/zar_xptr.c:717-765`; `bits == 1` branch
  `ArrowBitGet(values, from + i)` (~:746-749); fixed-width copy
  `values + from * width` (~:752).
- **Trigger (reproduced):**
  ```r
  sch <- .Call(zuarrow:::zar_c_schema_from_spec,
    list(format = "b", name = "", flags = 2L, metadata = NULL,
         children = list(), dictionary = NULL))
  mk <- function(len, bufs, nc = 0)
    .Call(zuarrow:::zar_c_array_from_buffers, sch,
          list(length = len, null_count = nc, offset = 0, buffers = bufs,
               children = list(), dictionary = NULL))
  # (a) all-null bool with NULL data buffer (legal Arrow): segfault
  .Call(zuarrow:::zar_c_array_slice, mk(10, list(as.raw(c(0, 0)), NULL), 10), 0, 10)
  # (b) 100 bits from a 2-byte buffer: garbage values
  arrow_to_r(.Call(zuarrow:::zar_c_array_slice, mk(100, list(NULL, as.raw(c(0xAA, 0xAA)))), 0, 100))
  ```
- **Why:** unlike `zar_c_array_decode` (`src/zar_xptr.c:613-618`), the slice
  never runs `ArrowArrayViewSetArray` + `zar_view_check_read` on the source
  and never handles `buffers[1] == NULL`.
- **Exported reach:** `zar_batch()` (`R/from-r.R:308`) slices a registered
  handler's array when a stream is batched, and a handler may return a
  foreign array with a NULL data buffer.
- **Fix:** validate the source view first (fail as `zuarrow_format_error`);
  treat a NULL data buffer as all-zero bits.

### R4 — `zar_c_from_r` accepts any `start`/`n`
- **Sources:** V:M1, G:G1 (both ranked #1).
- **Location:** `src/zar_from_r.c:1000-1001` (casts from `Rf_asReal`); the
  only guard, `Rf_xlength(x) < start + n` at `:886`, is bypassed by negative
  `start` and by overflow. Wild pointer reaches the int32 `memcpy` at `:253`.
- **Trigger (reproduced):**
  ```r
  s <- arrow_schema("i")
  arrow_to_r(.Call(zuarrow:::zar_c_from_r, 1:10, s, -5, 10))  # 8 10 0 0 0 1 2 3 4 5 (heap)
  .Call(zuarrow:::zar_c_from_r, 1:10, s, 2^62, 2^62)          # bus error, R aborts
  ```
- **Reach:** `:::` today; exported callers pass sane values, so any future
  R-layer bug reaches it.
- **Fix:** check type, `R_FINITE`, `start >= 0`, `n >= 0`, and the bound in
  double arithmetic before casting; make `:886` overflow-proof
  (`start > len || n > len - start`).

### R5 — `arrow_read()` with a forged `zuarrow_limits` reads past the vector
- **Sources:** V:M4, G:G4.
- **Location:** `src/zar_ipc_read.c:1090-1102` (`REAL(limits)[0..4]`, no type
  or length check); `R/read.R:115-117` / `:158-176` checks only
  `inherits(limits, "zuarrow_limits")`.
- **Trigger (reproduced; error varies with heap contents):**
  ```r
  path <- tempfile(fileext = ".arrows")
  arrow_write(data.frame(x = 1:3), path, format = "stream")
  arrow_read(path, limits = structure(list(max_message = 1e6), class = "zuarrow_limits"))
  ```
  `limits[names(formals(arrow_limits))]` pads missing fields with NULL and
  `unlist()` drops them, so C gets a length-1 double.
- **Fix:** in `zar_c_reader_open`, require `TYPEOF == REALSXP && length >= 5`,
  else a `type` failure; also validate the five fields in R.

### R8 — `zar_build_list` trusts `zar_list_prep` offsets
- **Sources:** V:M3, G:G3.
- **Location:** `src/zar_from_r.c:620-621` (`first`/`total` from
  `off[start]`, `off[start + n]`), used at `:648-649`.
- **Trigger (reproduced via `:::`):**
  ```r
  schema_l <- .Call(zuarrow:::zar_c_schema_from_spec,
    list(format = "+l", name = "", flags = 2L, metadata = NULL,
         children = list(list(format = "i", name = "item", flags = 2L, metadata = NULL,
                              children = list(), dictionary = NULL)), dictionary = NULL))
  x <- structure(list(offsets = c(-100, 5), null = FALSE, values = 1:5), class = "zar_list_prep")
  arrow_to_r(.Call(zuarrow:::zar_c_from_r, x, schema_l, 0, 1))  # 103 ints, heap then 1:5
  ```
  `offsets = c(NA, 5)` also passes (`(int64_t) NA_real_` is UB).
- **Reach:** `:::`; `arrow_array()` re-flattens a forged prep.
- **Fix:** for rows `[start, start + n]` check finite, non-decreasing,
  `off[start] >= 0`, `off[start + n] <= rows` before casting.

### R9 — C entry points read arguments at fixed positions without checks
- **Sources:** V:M8, G:G5.
- **Location:** `src/zar_to_r.c:2040-2046` (`VECTOR_ELT(opts, 0..4)`, only
  index 5 guarded; `INTEGER(to)[c]` unchecked), `src/zar_ipc_write.c:429-431`
  (`VECTOR_ELT(opts, 0..2)`), `src/zar_ipc_read.c:1137`
  (`INTEGER(columns)[k]`, no `TYPEOF`), `zar_c_reader_open`'s
  `STRING_ELT(source, 0)`, and R5.
- **Trigger:** `.Call(zuarrow:::zar_c_to_r, list(arrow_array(1:3)), arrow_schema("i"), list(1L))`.
- **Fix:** `TYPEOF` and `Rf_xlength` checks at each entry point, returning a
  `type` failure. `:::`-only today.

### R10 — row counts truncated to `int`
- **Sources:** V:M6, G:G8 (G adds the matrix path).
- **Location:**
  - `src/zar_to_r.c:1553` `INTEGER(rn)[1] = -(int)rows;` wraps past
    `INT_MAX`; negating `INT_MIN` is UB.
  - `src/zar_to_r.c:1745` allocates `rows * width` elements, then `:1771`
    `Rf_allocMatrix(…, (int)rows, (int)width)`; the transpose writes
    `rows * width` into the smaller matrix — heap overflow at e.g.
    `rows = 2^32`.
  - `R/to-r.R:330` `.set_row_names(as.integer(out$rows))` turns >2^31 into NA
    and errors with "missing value where TRUE/FALSE needed" (verified).
- **Reach:** needs >2^31 rows; the only C bound is `R_XLEN_T_MAX` (`:2071`).
- **Fix:** fail with a `limit` failure when `rows > INT_MAX` for data frames
  and `to = arrow_matrix()`. Unit-test with a stubbed row count.

---

## Wrong results

### R6 — writer emits nested dictionaries in dependency-invalid order
- **Sources:** V:M10, G:G11, C:#3 (P2).
- **Location:** `src/zar_ipc_write.c:380-393` (`zar_collect_dicts`: own
  dictionary, then children, then dictionary subtree) and `:548-582`
  (emission in collect order, `id = k`).
- **Trigger (reproduced, stream and file):**
  ```r
  devtools::load_all(".", quiet = TRUE); source("tests/testthat/helper-arrays.R")
  inner <- zspec("i", "a"); inner$dictionary <- zspec("u")
  outer <- zspec("i", "x"); outer$dictionary <- zspec("+s", children = list(inner))
  schema <- test_schema(zspec("+s", children = list(outer)))
  a <- test_array(schema, 2, list(NULL), children = list(test_array_spec(2,
    list(NULL, le_int(c(0, 1), 4L)), dictionary = test_array_spec(2, list(NULL),
    children = list(test_array_spec(2, list(NULL, le_int(c(1, 0), 4L)),
    dictionary = test_array_spec(2, list(NULL, le_int(c(0, 3, 6), 4L), charToRaw("foobar")))))))))
  arrow_validate(a)                       # TRUE; arrow_to_r(a) correct
  arrow_read(arrow_write(a, NULL, format = "stream"))
  #> [0] Expected dictionary index >= 0 and < 0 but found value 1
  ```
- **Why:** the IPC format requires dictionary batches dependencies-first.
- **Fix:** keep schema-assigned ids independent of emission order and emit
  post-order (subtree before the node's own dictionary). Or reject the layout
  explicitly until supported.
- **Test gap:** the existing "dictionary of nested values" test covers
  `dictionary<struct<int32>>` only. Add nested cases with changing
  dictionaries and compression, checked by independent readers.

### R7 — ALTREP `No_NA` goes stale after native `Set_elt`
- **Sources:** G:G7, C:#4 (P2). Not in V.
- **Location:** `src/zar_altrep.c:170-180` (`zar_deferred_set_elt` writes the
  cache; `zar_deferred_no_na` still reads the Arrow validity buffers).
- **Trigger (reproduced with the package's probe hook):**
  ```r
  v <- arrow_to_r(arrow_array(c("a", "b", "c")), copy = FALSE)
  invisible(.Call(zuarrow:::zar_c_deferred_probe, v, 3L, 1L, NA_character_))
  is.na(v[[1L]])                                           # TRUE
  .Call(zuarrow:::zar_c_deferred_probe, v, 4L, NULL, NULL) # TRUE — stale
  ```
  Ordinary `v[1] <- NA` materializes first in R 4.5/4.6, so only native
  callers see it.
- **Fix:** answer `No_NA` from the cache once materialized, or drop the
  optional method. Test NA insertion and removal through `Set_elt` and the
  writable-pointer path.

### R11 — factor level count checked after codes are written
- **Sources:** V:M7, G:G9.
- **Location:** `src/zar_to_r.c:1818` (`(int)remap[idx] + 1`) vs. the
  `levels.n > INT_MAX` check at `:1821`, after the loop.
- **Reach:** >2^31 distinct dictionary values across batches.
- **Fix:** fail with a `limit` failure in `zar_levels_add` on level
  `INT_MAX + 1`.

### R13 — registry `to` pieces combined with `c()` lose classes
- **Sources:** G:G13. Not in V or C.
- **Location:** `zar_apply_handler` in `R/to-r.R`
  (`do.call(c, unname(pieces))`).
- **Trigger:** a `to` handler returning a factor over a 2-batch stream
  returns plain integers.
- **Note:** the behaviour is documented ("pieces are combined with `c()`"),
  so it is a trap for handler authors rather than a bug.
- **Fix:** call the handler once on the whole column, or enforce/document the
  type constraint at registration.

---

## Build

### R12 — header-only changes don't rebuild objects
- **Sources:** G:G12, C:#5 (P2).
- **Location:** `src/Makevars:22`, `src/Makevars.win:22`.
- **Trigger (reproduced):** copy a built `src/` tree preserving timestamps,
  touch `zar.h` and `vendor/nanoarrow/nanoarrow.h`,
  `R CMD SHLIB --dry-run -o zuarrow.so zuarrow.c` → "Nothing to be done".
- **Impact:** incremental dev reinstalls only; a clean tarball build is fine.
- **Fix:** header prerequisites for first-party, vendor public and generated
  FlatBuffers headers (or portable dependency generation); add an
  incremental-build CI check.

---

## Further review priorities (C, not reproduced failures)

- **Allocation-failure ordering.** Owning constructors `malloc()` the struct
  before `R_MakeExternalPtr()` and the finalizer; an R allocation that
  longjmps in between leaks it, and the comment saying the order prevents
  a leak is misleading. The writer already creates and registers an empty
  pointer first. **Note:** V and G list "malloc'd structs owned by finalizers
  registered immediately" as clean; C disagrees. Resolve by inspection.
- **Fuzzing beyond `ZAR_STANDALONE`.** The standalone target stubs the codecs
  and omits writer, conversion and ALTREP paths. Add real-codec and
  structured multi-message targets (dictionary transitions, reader/writer
  round trips).
- **Total decoded-byte budget.** `max_bytes` bounds input and `max_message`
  each buffer; nothing bounds the cumulative decoded size of an eager read.
  The delta-dictionary budget covers one amplification path only.
- **Vendor patches are maintained features.** 16 patches add real IPC
  behaviour. Give each behavioural patch named regression tests, independent
  compatibility checks and upstream tracking.
- **Interrupts in long conversions.** No first-party loop checks
  `R_CheckUserInterrupt`, by design. Cleanup guards or smaller work units
  would allow it without leaks.
- **Portability note (V, G).** `zar_parse.c` uses `__builtin_*_overflow`,
  GCC/Clang only; fine for R's toolchains.

---

## Areas reviewed clean (V, G)

- PROTECT/UNPROTECT balanced on traced paths in `zar_xptr.c`, `zar_to_r.c`,
  `zar_from_r.c`, `zar_ipc_write.c`; `zar_scratch`/`zar_writer` finalizers
  idempotent (but see allocation ordering above).
- NA/NaN/Inf: `ZAR_NA_DBL` uses `ISNAN && R_IsNA`; `c(NaN, NA, Inf, -0)`
  round-trips; NaN into an int target is a lossy error.
- `zar_c_to_r` validates every batch (full level + layout + UTF-8) before
  filling; out-of-range dictionary indices, short REE runs, short offsets on
  empty strings and empty structs give `zuarrow_format_error`.
- Zero-length inputs across layouts; short columns error rather than recycle.
- Deferred strings: a released backing handle gives `zuarrow_handle_error`.
- Registration: `R_useDynamicSymbols(FALSE)`, `R_forceSymbols(TRUE)`, every
  `zar_c_*` used in `R/` and tests registered (V counted 33 entries, G 34 —
  recount when touching `zuarrow.c`). `NAMESPACE` `useDynLib` matches.
- Makevars: `$(C_VISIBILITY)`, no `-w`, explicit vendor objects.
- Patches 0001-0014 and 0016 spot-checked clean (0015 is R1); 0016
  interacts with R6.
- Vendoring machinery (pinned release, SHA-512, reproducible derivation,
  hidden symbols, sanitizer/rchk CI) called a strength by C.

---

## Tests to add

One regression test per finding, in the file that owns the path:

- R1: empty delta for each binary/string type; input into `tests/testthat/data/`.
- R2: batch outlives a dropped stream (registry whole-column borrow); stream
  moved out of its wrapper before `gc()`.
- R3: slice of all-null bool with NULL data buffer; slice of short buffer is a
  format error.
- R4, R8, R9: hostile `.Call` arguments give `zuarrow_type_error`, not a crash.
- R5: forged `zuarrow_limits` gives a type error.
- R6: nested dictionary round trip, stream and file, plus an oracle reader.
- R7: native mutate-then-`No_NA` through `zar_c_deferred_probe`.
- R10, R11: `rows > INT_MAX` / `levels > INT_MAX` guards with stubbed counts.
- R13: factor-returning handler over two batches.

### Broader edge-case inputs (from V and G)

```r
library(zuarrow)
# empty / all-NA / NaN-Inf mixes, per type
for (v in list(numeric(), integer(), logical(), character(),
               rep(NA_real_, 3), c(NaN, Inf, -Inf, NA), c(1, NA),
               c("a", NA, ""), list(), list(NULL, 1:2), NULL)) {
  a <- tryCatch(arrow_array(v), error = identity)
  if (!inherits(a, "error")) print(tryCatch(arrow_to_r(a), error = conditionMessage))
}
# schema-driven coercions
arrow_to_r(arrow_array(1:3, schema = "g"))                   # int -> double, quiet
arrow_to_r(arrow_array(c(1.5, 2), schema = "i"))             # lossy error, row named
arrow_to_r(arrow_array(c(2^31, -1), schema = "i"))           # out of range
arrow_to_r(arrow_array(2^53 + 2, schema = "l"), lossy = "character")
arrow_to_r(arrow_array(-2147483648L, schema = "i"))          # INT32_MIN vs NA sentinel
# matrices: dimnames with duplicates, non-contiguous, zero rows, 3-d
m <- matrix(1:6, 2, 3, dimnames = list(c("r", "r"), c("a", "b", "c")))
arrow_to_r(arrow_array(m, schema = arrow_matrix()))
arrow_to_r(arrow_array(m[2:1, , drop = FALSE], schema = arrow_matrix()))
arrow_to_r(arrow_array(matrix(integer(), 0, 3), schema = arrow_matrix()))
arrow_to_r(arrow_array(array(1:8, c(2, 2, 2))))
# list columns: empty elements, NULLs, nested
arrow_to_r(arrow_array(list(NULL, integer(), 1:3)))
arrow_to_r(arrow_array(list(data.frame(a = 1:2), data.frame(a = 3:4))))
# factors: NA codes, unused levels, batches with new levels
arrow_to_r(arrow_array(factor(c("a", NA, "b"))))
arrow_to_r(arrow_array(factor(character(), levels = "x")))
arrow_stream(data.frame(f = factor(c("a", "b", "b"))), batch = 1)
# round trips
df <- data.frame(x = 1:3, f = factor(c("a", "b", "a")), s = c("x", NA, "z"))
arrow_read(arrow_write(df, NULL))
arrow_read(arrow_write(df, NULL, format = "stream"))
# deferred strings: materialization paths
v <- arrow_to_r(arrow_array(c("a", "b", "c")), copy = FALSE)
serialize(v, NULL); v[1] <- "z"
# deferred strings: released handle gives zuarrow_handle_error, not a UAF
s <- arrow_stream(data.frame(x = c("a", "b", "c")), batch = 2)
b <- .Call(zuarrow:::zar_c_stream_next, s)
v <- .Call(zuarrow:::zar_c_to_r, list(b), arrow_schema(s),
           list(1L, integer(), FALSE, TRUE, 64L, FALSE))$columns[[1]]
.Call(zuarrow:::zar_c_test_release, b, FALSE); v[1]
# sliced struct child with offset
cs <- .Call(zuarrow:::zar_c_array_child, arrow_array(data.frame(a = 1:4)), 0L)
arrow_to_r(.Call(zuarrow:::zar_c_array_slice, cs, 1, 2))
# near-2^31 scale (R10, R11)
big <- arrow_array(rep(1L, 5e8), schema = "i")
```
