# Probes for the 2026-11-11 bug hunt

These are the scripts that reproduced a finding, copied from the hunt's
scratch directory. They were written against an install of `ff3dcba` in a
scratch library. Some of them hard-code that scratch root as `W` (in
`hunt-1/pre.R`, `hunt-2/common.R` and `hunt-3/lib.R`). Point `W` at your
own build first:

```sh
W=$(mktemp -d); mkdir -p "$W/src" "$W/lib"
git archive ff3dcba | tar -x -C "$W/src"
R CMD INSTALL --library="$W/lib" "$W/src"
```

- `drivers/Makevars-asan` and `drivers/Rscript-asan`: the ASan and UBSan
  build of the package on macOS, loaded with `DYLD_INSERT_LIBRARIES`.
  Install with `R CMD INSTALL --no-test-load`.
- `drivers/replay.c`: a `main()` that replays files through
  `tools/fuzz/harness.c`. Apple clang has no libFuzzer. Compile it with the
  flags in `.github/workflows/fuzz.yaml`.
- `coordinator/`: the coordinator's re-runs of every trigger (`h1.R`,
  `f1.R`, `f3.R`, `f9.R`, `h2.R`, `sib*.R`), and the generator `gen.R`
  for deep struct and map schemas.
- `hunt-1/`, `hunt-2/` and `hunt-3/`: each hunter's scripts. Run them from
  their own directory, because they `source()` a common file.
- `target-map.md`: the map the hunters were sliced from.
