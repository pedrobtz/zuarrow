# Installs the heavy Suggests as binaries on the R-devel Linux legs of CI,
# before r-actions installs the Suggests (its `pre-install` input). No
# repository those legs use has R-devel binaries of duckdb or arrow, and
# building duckdb from source took longer than the job timeout.
# cran.r-universe.dev builds CRAN's releases for R-devel on one distro,
# Ubuntu 26.04 (resolute), which the r-hub images use. pak then keeps them,
# since they satisfy DESCRIPTION.
#
# Elsewhere r-universe serves source tarballs (the noble runners) or nothing
# (gcc-asan's Fedora), so a package is installed only if the repository
# lists it as built. Anything else does nothing and falls through to the
# ordinary install, and on the runners to its cache.

heavy <- c("duckdb", "arrow")

if (
  R.version$status != "Under development (unstable)" ||
    Sys.info()[["sysname"]] != "Linux" ||
    !file.exists("/etc/os-release")
) {
  quit(save = "no")
}

os <- readLines("/etc/os-release")
codename <- sub(".*=", "", grep("^VERSION_CODENAME=", os, value = TRUE))
if (length(codename) != 1L || !nzchar(codename)) {
  quit(save = "no")
}
rv <- paste(R.version$major, sub("[.].*", "", R.version$minor), sep = ".")
repo <- sprintf(
  "https://cran.r-universe.dev/bin/linux/%s-%s/%s/",
  codename,
  R.version$arch,
  rv
)

available <- tryCatch(
  available.packages(repos = repo, fields = "Built"),
  error = function(e) NULL
)
if (is.null(available)) {
  message("No package index at ", repo)
  quit(save = "no")
}
built <- rownames(available)[!is.na(available[, "Built"])]
wanted <- intersect(heavy, built)
if (length(wanted) == 0L) {
  message("No binaries of ", toString(heavy), " at ", repo)
  quit(save = "no")
}

message("Installing binaries of ", toString(wanted), " from ", repo)
tryCatch(
  install.packages(wanted, repos = repo, available = available),
  error = function(e) message("Binary install failed: ", conditionMessage(e))
)
