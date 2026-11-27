#!/usr/bin/env bash
# The consumer fixture of design section 14.1, end to end: zuarrow from
# this checkout, then tools/zuarrowlink, which has only LinkingTo: zuarrow
# and links the installed libzuarrow.a by its own ./configure, as zucsv,
# qio, zujson and zugodb will. Called by consumer.yaml on Linux, macOS and
# Windows. Run from the package root with testthat installed; zuarrow's own
# dependencies (zukomp) must be installed too.
set -eu

# Relative paths: on Windows the compiler is a native binary that does not
# understand a Git Bash /tmp path.
WORK=./.check-consumer
LIB="$WORK/lib"
rm -rf "$WORK"
mkdir -p "$LIB"
trap 'rm -rf "$WORK"' EXIT

echo "==> installing zuarrow"
R CMD INSTALL --preclean --no-multiarch --library="$LIB" .

echo "==> the archive, its headers and nanoarrow's licence are installed"
ZUARROW_LIB=$(R_LIBS="$LIB" Rscript --vanilla -e 'arch <- .Platform$r_arch; d <- if (nzchar(arch)) system.file("lib", arch, package = "zuarrow") else ""; if (!nzchar(d)) d <- system.file("lib", package = "zuarrow"); cat(d)')
[ -f "$ZUARROW_LIB/libzuarrow.a" ] || { echo "FAIL: libzuarrow.a is not installed" >&2; exit 1; }
for f in include/zuarrow.h include/zukomp.h include/zuarrow/nanoarrow.h \
  licenses/nanoarrow-LICENSE.txt licenses/nanoarrow-NOTICE.txt; do
  [ -f "$LIB/zuarrow/$f" ] || { echo "FAIL: $f is not installed" >&2; exit 1; }
done

echo "==> the fixture declares no run-time dependency on zuarrow"
if grep -qE '^(Imports|Depends):' tools/zuarrowlink/DESCRIPTION; then
  echo "FAIL: zuarrowlink declares Imports or Depends; it must link, not load" >&2
  exit 1
fi
if grep -qE '^\s*(import|importFrom)\(' tools/zuarrowlink/NAMESPACE; then
  echo "FAIL: zuarrowlink imports a namespace; it must link, not load" >&2
  exit 1
fi

echo "==> the fixture's IPC files are what this zuarrow writes"
R_LIBS="$LIB" Rscript --vanilla tools/make-consumer-fixture.R --check

echo "==> installing the fixture (its configure resolves the archive)"
R_LIBS="$LIB" R CMD INSTALL --preclean --no-multiarch --library="$LIB" tools/zuarrowlink

# On macOS a dropped PKG_LIBS still links (R links with -undefined
# dynamic_lookup) and would fail only at load, or bind to zuarrow.so's
# hidden copy never. On Linux and Windows the link itself fails. Where nm
# can read the object, the archive's code must be in it and none of it
# exported.
so=$(find "$LIB/zuarrowlink/libs" -name 'zuarrowlink.*' | head -1)
if command -v nm >/dev/null 2>&1 && [ -n "$so" ] && [ "$(nm "$so" 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
  echo "==> the archive is linked into the fixture and not exported"
  u=$(nm -u "$so" 2>/dev/null | grep -c 'zuarrow' || true)
  [ "$u" = "0" ] || { echo "FAIL: $u zuarrow symbols are undefined in $so" >&2; exit 1; }
  d=$(nm "$so" 2>/dev/null | grep -cE ' [Tt] _*zuarrow_open_stream$' || true)
  [ "$d" != "0" ] || { echo "FAIL: zuarrow_open_stream is not in $so" >&2; exit 1; }
  case "$(uname -s)" in
    Darwin) exported=$(nm -gU "$so" | grep -v 'R_init_zuarrowlink' | grep -c 'zuarrow\|zar_\|flatcc' || true) ;;
    Linux) exported=$(nm -D --defined-only "$so" | grep -v 'R_init_zuarrowlink' | grep -c 'zuarrow\|zar_\|flatcc' || true) ;;
    *) exported=0 ;;
  esac
  [ "$exported" = "0" ] || { echo "FAIL: $so exports $exported archive symbols" >&2; exit 1; }
fi

# Via a file, not `Rscript -e`: on Windows only the first line of a
# multi-line -e argument reaches R.
cat > "$WORK/run-tests.R" <<'RUN_TESTS_R'
results <- as.data.frame(testthat::test_local(
  "tools/zuarrowlink", reporter = "summary", load_package = "installed"))
# A zero-row result proved nothing.
if (nrow(results) == 0L || sum(results$passed) == 0L) {
  stop("no consumer tests ran")
}
quit(status = as.integer(any(results$failed > 0 | results$error)))
RUN_TESTS_R

echo "==> the fixture's tests, with zuarrow as the oracle"
R_LIBS="$LIB" ZUARROWLINK_ORACLE=true Rscript --vanilla "$WORK/run-tests.R"

echo "==> the fixture's tests with zuarrow absent from the library"
# CI installs zuarrow's dependencies and testthat, never zuarrow itself,
# outside $LIB; absent.R fails if one is reachable anyway, so this step
# cannot pass with zuarrow standing in. (Locally, a zuarrow in the user
# library makes it fail; uninstall it, or run on CI.)
mv "$LIB/zuarrow" "$WORK/zuarrow-hidden"
cat > "$WORK/absent.R" <<'ABSENT_R'
if (nzchar(system.file(package = "zuarrow"))) {
  stop("zuarrow is still reachable at ", system.file(package = "zuarrow"))
}
ABSENT_R
R_LIBS="$LIB" Rscript --vanilla "$WORK/absent.R"
R_LIBS="$LIB" Rscript --vanilla "$WORK/run-tests.R"
mv "$WORK/zuarrow-hidden" "$LIB/zuarrow"
echo "==> the consumer builds, links, builds arrays and reads IPC on $(uname -s)"
