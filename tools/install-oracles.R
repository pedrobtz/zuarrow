# Installs the oracle packages of design section 9 (arrow, nanoarrow, DBI,
# duckdb) as Linux binaries, for the oracles workflow. None of them is a
# dependency of zuarrow; see tests/testthat/helper-ci-oracles.R.
#
# arrow and duckdb take a long time to build from source, so this installs
# binaries only and never builds: Posit Package Manager first, then
# r-universe's CRAN builds. A package neither has for this platform is an
# error, and the workflow step's time limit stops a source build.
#
# Linux only: the binary repositories below serve Linux builds, and the
# workflow runs on Ubuntu. Run with `Rscript tools/install-oracles.R`.

oracles <- c("arrow", "nanoarrow", "DBI", "duckdb")

if (Sys.info()[["sysname"]] != "Linux") {
  stop("tools/install-oracles.R installs Linux binaries; run it on Linux.")
}

os_release <- function(field) {
  lines <- readLines("/etc/os-release")
  value <- sub(
    paste0("^", field, "="),
    "",
    grep(paste0("^", field, "="), lines, value = TRUE)
  )
  gsub('"', "", value)
}
codename <- os_release("VERSION_CODENAME")
arch <- R.version$arch
rver <- paste(R.version$major, sub("\\..*$", "", R.version$minor), sep = ".")

# Package Manager serves binaries only to a user agent naming R's version
# and platform.
options(
  HTTPUserAgent = sprintf(
    "R/%s R (%s)",
    getRversion(),
    paste(getRversion(), R.version$platform, R.version$arch, R.version$os)
  )
)

repos <- c(
  p3m = sprintf("https://p3m.dev/cran/__linux__/%s/latest", codename),
  universe = sprintf(
    "https://cran.r-universe.dev/bin/linux/%s-%s/%s",
    codename,
    arch,
    rver
  )
)

lib <- .libPaths()[[1L]]
for (package in oracles) {
  installed <- FALSE
  for (name in names(repos)) {
    available <- tryCatch(
      available.packages(repos = repos[[name]], type = "source"),
      error = function(e) NULL
    )
    if (is.null(available) || !package %in% rownames(available)) {
      next
    }
    # Both repositories serve Linux binaries under type "source". Nothing
    # here can tell a binary from a source build before installing, so the
    # workflow step's time limit is what stops a source build.
    message(sprintf("Installing %s from %s", package, name))
    ok <- tryCatch(
      {
        install.packages(
          package,
          lib = lib,
          repos = c(repos[[name]], repos[names(repos) != name]),
          dependencies = c("Depends", "Imports", "LinkingTo"),
          Ncpus = 2L,
          quiet = TRUE
        )
        requireNamespace(package, lib.loc = lib, quietly = TRUE)
      },
      error = function(e) FALSE,
      warning = function(w) FALSE
    )
    if (isTRUE(ok)) {
      installed <- TRUE
      break
    }
  }
  if (!installed) {
    stop(sprintf("No Linux binary of %s could be installed.", package))
  }
}

for (package in oracles) {
  message(sprintf(
    "%s %s: %s",
    package,
    utils::packageVersion(package),
    utils::packageDescription(package)$Built
  ))
}
