# Symbol tables of the loaded zuarrow shared object, read with the binutils
# the toolchain ships: nm on Linux and macOS, objdump on Windows. Names are
# returned without the leading underscore macOS adds and without a glibc
# version suffix.
# Coverage instrumentation adds gcov's own exports and imports, so the
# symbol tests describe the shipped object only when it is not instrumented.
abi_skip_instrumented <- function() {
  testthat::skip_if(
    identical(Sys.getenv("R_COVR"), "true"),
    "the shared object is instrumented for coverage"
  )
}

abi_dll_path <- function() {
  getLoadedDLLs()[["zuarrow"]][["path"]]
}

# A symbol table that can't be read ends the test. On CI, where the guards
# must run, that is a failure; elsewhere, such as a machine without
# binutils, it is a skip. The tests skip_on_cran() themselves.
abi_unavailable <- function(reason) {
  if (nzchar(Sys.getenv("CI"))) {
    testthat::fail(paste0(reason, ", so the ABI guard can't run on CI"))
  }
  testthat::skip(reason)
}

abi_tool <- function(name) {
  path <- Sys.which(name)
  if (!nzchar(path)) {
    abi_unavailable(paste(name, "is not on the PATH"))
  }
  path
}

abi_run <- function(tool, args) {
  out <- suppressWarnings(system2(tool, args, stdout = TRUE, stderr = FALSE))
  if (!is.null(attr(out, "status"))) {
    abi_unavailable(paste(basename(tool), "failed"))
  }
  out
}

abi_clean <- function(x) {
  x <- sub("@.*$", "", x)
  if (Sys.info()[["sysname"]] == "Darwin") {
    x <- sub("^_", "", x)
  }
  x
}

abi_objdump <- function(path = abi_dll_path()) {
  abi_run(abi_tool("objdump"), c("-p", shQuote(path)))
}

# On Windows every DLL links the mingw-w64 runtime, whose startup code
# imports abort, exit and the stdio table itself. R CMD check keeps only the
# DLL symbols that the package's own object files reference (symbols.rds),
# so it never reports them. These are the imports of an empty DLL built
# with the same toolchain, so the guard can count only what zuarrow adds.
abi_runtime_imports <- function() {
  if (.Platform$OS.type != "windows") {
    return(character())
  }
  dir <- tempfile("abi-baseline")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)
  writeLines("void zar_abi_baseline(void) {}", file.path(dir, "baseline.c"))
  r <- file.path(R.home("bin"), "R")
  status <- withr::with_dir(
    dir,
    suppressWarnings(system2(
      r,
      c("CMD", "SHLIB", "baseline.c"),
      stdout = FALSE,
      stderr = FALSE
    ))
  )
  dll <- file.path(dir, paste0("baseline", .Platform$dynlib.ext))
  if (!identical(status, 0L) || !file.exists(dll)) {
    abi_unavailable("R CMD SHLIB could not build the baseline DLL")
  }
  abi_objdump_imports(abi_objdump(dll))
}

abi_exports <- function() {
  if (.Platform$OS.type == "windows") {
    out <- abi_objdump()
    start <- grep("[Ordinal/Name Pointer] Table", out, fixed = TRUE)
    if (length(start) != 1L) {
      abi_unavailable("objdump printed no export table")
    }
    rows <- out[-seq_len(start)]
    rows <- rows[grepl("^\\s*\\[\\s*[0-9]+\\]", rows)]
    return(sub("^.*\\s", "", trimws(rows)))
  }
  nm <- abi_tool("nm")
  args <- if (Sys.info()[["sysname"]] == "Darwin") {
    c("-gU", shQuote(abi_dll_path()))
  } else {
    c("-D", "--defined-only", shQuote(abi_dll_path()))
  }
  out <- abi_run(nm, args)
  abi_clean(sub("^.*\\s", "", trimws(out[nzchar(out)])))
}

abi_imports <- function() {
  if (.Platform$OS.type == "windows") {
    return(abi_objdump_imports(abi_objdump()))
  }
  out <- abi_run(abi_tool("nm"), c("-u", shQuote(abi_dll_path())))
  abi_clean(sub("^.*\\s", "", trimws(out[nzchar(out)])))
}

# The member names of objdump -p's import tables. Each DLL's table starts at
# a "vma:" header and ends at a blank line. Its rows are the address, then
# the hint, or with binutils 2.41 and later the ordinal and the hint, then
# the name, so the name is the last field whatever the column count.
abi_objdump_imports <- function(out) {
  out <- sub("\\s+$", "", out)
  start <- grep("^\\s*vma:", out)
  if (length(start) == 0L) {
    abi_unavailable("objdump printed no import table")
  }
  names <- character()
  for (i in start) {
    j <- i + 1L
    while (j <= length(out) && nzchar(trimws(out[j]))) {
      names <- c(names, sub("^.*\\s", "", trimws(out[j])))
      j <- j + 1L
    }
  }
  names
}

# The symbols R CMD check's compiled-code check reports, across platforms,
# with leading underscores removed so one list covers macOS too.
abi_forbidden <- c(
  "abort",
  "exit",
  "_exit",
  "_Exit",
  "printf",
  "puts",
  "putchar",
  "sprintf",
  "vprintf",
  "vsprintf",
  "sprintf_chk",
  "vsprintf_chk",
  "rand",
  "random",
  "rand_r",
  "srand",
  "srandom",
  "srand48",
  "stderr",
  "stdout",
  "stderrp",
  "stdoutp",
  "iob_func",
  "acrt_iob_func",
  "assert",
  "assert_fail",
  "assert_rtn"
)

# ---- the static archive (design section 14.1) ---------------------------

# The installed libzuarrow.a: under lib/<r_arch> (lib/x64 on Windows), or
# lib on single-arch platforms. Under devtools, before any install, the one
# src/Makevars built in the source tree.
abi_archive_path <- function() {
  arch <- .Platform$r_arch
  candidates <- c(
    if (nzchar(arch)) {
      system.file("lib", arch, "libzuarrow.a", package = "zuarrow")
    },
    system.file("lib", "libzuarrow.a", package = "zuarrow"),
    test_path("..", "..", "src", "libzuarrow.a")
  )
  candidates <- candidates[nzchar(candidates) & file.exists(candidates)]
  if (length(candidates) == 0L) {
    abi_unavailable("libzuarrow.a is not installed")
  }
  candidates[[1]]
}

abi_archive_nm <- function(args) {
  path <- shQuote(abi_archive_path())
  out <- abi_archive_symbols(abi_run(abi_tool("nm"), c(args, path)))
  # Under an LTO configuration the archive holds bitcode (src/Makevars),
  # which plain nm lists as nothing; gcc-nm reads GCC's through its plugin.
  if (length(out) == 0L && nzchar(Sys.which("gcc-nm"))) {
    out <- abi_archive_symbols(abi_run(Sys.which("gcc-nm"), c(args, path)))
  }
  if (length(out) == 0L || any(grepl("__gnu_lto|\\.gnu\\.lto", out))) {
    testthat::skip(
      "libzuarrow.a holds LTO bitcode, which has no object symbols to judge"
    )
  }
  out
}

# nm's lines without blank lines and archive member headers ("x.o:").
abi_archive_symbols <- function(out) {
  out[nzchar(trimws(out)) & !grepl(":$", out)]
}

# Symbol names in nm's default format, without archive member headers.
abi_archive_names <- function(args) {
  out <- abi_archive_nm(args)
  abi_clean(sub("^.*\\s", "", trimws(out)))
}

abi_archive_undefined <- function() unique(abi_archive_names("-u"))

abi_archive_defined_globals <- function() {
  args <- if (Sys.info()[["sysname"]] == "Darwin") {
    "-gU"
  } else {
    c("-g", "--defined-only")
  }
  unique(abi_archive_names(args))
}

# Defined symbols in a writable data section, which would be mutable state
# shared by every stream in a process. Sanitizer and compiler bookkeeping
# (asan, ubsan, coverage, local labels, section symbols) is not the
# package's. A static that is never written but not const counts: Linux
# puts it in .data (patch 0023).
abi_archive_writable <- function() {
  if (Sys.info()[["sysname"]] == "Darwin") {
    out <- abi_archive_nm("-m")
    hits <- out[grepl(
      "\\(__DATA,__(data|bss|common)\\)|\\(__DATA,__thread",
      out
    )]
    names <- sub("^.*\\s", "", trimws(hits))
  } else {
    out <- abi_archive_nm(c("-f", "sysv", "--defined-only"))
    rows <- strsplit(out[grepl("\\|", out)], "\\|")
    rows <- rows[lengths(rows) >= 7L]
    section <- trimws(vapply(rows, `[[`, "", 7L))
    names <- trimws(vapply(rows, `[[`, "", 1L))
    writable <- grepl("^\\.(data|bss|tdata|tbss)", section) &
      !grepl("^\\.data\\.rel\\.ro", section)
    names <- names[writable | section %in% c("*COM*", "COMMON")]
  }
  names <- abi_clean(names)
  # COFF's nm lists each section as a symbol of its own name (".data").
  names[
    !grepl(
      "^(\\.|L[0-9_.]|l_|ltmp|__odr_)|asan|ubsan|sancov|gcov|__llvm",
      names
    )
  ]
}
