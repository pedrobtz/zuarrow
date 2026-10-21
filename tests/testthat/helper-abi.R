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

abi_tool <- function(name) {
  path <- Sys.which(name)
  testthat::skip_if(!nzchar(path), paste(name, "is not on the PATH"))
  path
}

abi_run <- function(tool, args) {
  out <- suppressWarnings(system2(tool, args, stdout = TRUE, stderr = FALSE))
  testthat::skip_if(
    !is.null(attr(out, "status")),
    paste(basename(tool), "failed")
  )
  out
}

abi_clean <- function(x) {
  x <- sub("@.*$", "", x)
  if (Sys.info()[["sysname"]] == "Darwin") {
    x <- sub("^_", "", x)
  }
  x
}

abi_objdump <- function() {
  abi_run(abi_tool("objdump"), c("-p", shQuote(abi_dll_path())))
}

abi_exports <- function() {
  if (.Platform$OS.type == "windows") {
    out <- abi_objdump()
    start <- grep("[Ordinal/Name Pointer] Table", out, fixed = TRUE)
    testthat::skip_if(length(start) != 1L, "no export table found")
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
    out <- abi_objdump()
    rows <- out[grepl("^\\s+[0-9a-f]+\\s+[0-9]+\\s+\\S+$", out)]
    return(sub("^.*\\s", "", trimws(rows)))
  }
  out <- abi_run(abi_tool("nm"), c("-u", shQuote(abi_dll_path())))
  abi_clean(sub("^.*\\s", "", trimws(out[nzchar(out)])))
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
