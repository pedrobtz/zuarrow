## Installs the shared object, and beside it the LinkingTo surface of
## design section 14.1: libzuarrow.a, the R-free IPC reader and nanoarrow
## that src/Makevars compiles a second time with -DZAR_STANDALONE, and the
## headers a reader compiles against.
##
## Defining this file makes R stop installing the shared object by itself,
## so the first block is not optional: without it the package installs with
## no compiled code at all (Writing R Extensions 1.2.1.1).

zar_install <- function(from, to, what) {
  dir.create(to, recursive = TRUE, showWarnings = FALSE)
  ## file.copy() returns a logical per source and never signals, so an
  ## unchecked copy is how a package installs with a piece missing.
  ok <- file.copy(from, to, overwrite = TRUE)
  if (length(ok) == 0L || !all(ok)) {
    stop("zuarrow: failed to install ", what, " into ", to)
  }
  invisible(TRUE)
}

libs <- file.path(R_PACKAGE_DIR, paste0("libs", R_ARCH))
zar_install(Sys.glob(paste0("*", SHLIB_EXT)), libs, "the shared object")
if (file.exists("symbols.rds")) {
  zar_install("symbols.rds", libs, "symbols.rds")
}

## The archive is object code for this architecture, so it goes under
## R_ARCH as the shared object does: <pkg>/lib on Unix, <pkg>/lib/x64 on
## Windows. A consumer finds it with system.file("lib", .Platform$r_arch,
## package = "zuarrow"), falling back to system.file("lib", ...).
lib <- file.path(R_PACKAGE_DIR, paste0("lib", R_ARCH))
zar_install(
  "libzuarrow.a",
  lib,
  "libzuarrow.a (src/Makevars should have built it)"
)

## zuarrow.h is in inst/include, which R copies afterwards, merging into
## this directory. Two headers are copied rather than kept twice, so
## neither can drift from what the archive was compiled against:
##
## - nanoarrow.h from the vendored tree, as zuarrow/nanoarrow.h. The
##   subdirectory keeps it apart from the nanoarrow package's own header of
##   that name for a consumer that links both.
## - zukomp.h from the zukomp this build compiled against, which types the
##   codec table in zuarrow_options. zuarrow.h includes it by its quoted
##   name, so the copy beside it is found first, and a consumer needs only
##   LinkingTo: zuarrow.
include <- file.path(R_PACKAGE_DIR, "include")
zar_install(
  file.path("vendor", "nanoarrow", "nanoarrow.h"),
  file.path(include, "zuarrow"),
  "nanoarrow.h"
)
zukomp_h <- file.path(find.package("zukomp"), "include", "zukomp.h")
zar_install(zukomp_h, include, "zukomp.h (from the installed zukomp)")

## nanoarrow's licence and notice travel with the archive and the header,
## which hold Apache-2.0 code (design section 7).
licenses <- file.path(R_PACKAGE_DIR, "licenses")
dir.create(licenses, recursive = TRUE, showWarnings = FALSE)
for (f in c("LICENSE.txt", "NOTICE.txt")) {
  if (
    !file.copy(
      file.path("vendor", "nanoarrow", f),
      file.path(licenses, paste0("nanoarrow-", f)),
      overwrite = TRUE
    )
  ) {
    stop("zuarrow: failed to install nanoarrow's ", f)
  }
}
