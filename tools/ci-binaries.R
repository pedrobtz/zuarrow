# Installs duckdb as a binary on the R-devel Linux legs of CI, before
# r-actions installs the Suggests (its `pre-install` input). No repository
# those legs use has an R-devel binary of duckdb, and building it from source
# took longer than the job timeout. cran.r-universe.dev builds CRAN's
# release for R-devel on Ubuntu (resolute, the r-hub images; noble, the
# runners). pak then keeps it, since it satisfies DESCRIPTION.
#
# Anything else (R-release, macOS, Windows, gcc-asan's Fedora, a binary that
# is missing or fails to install) does nothing and falls through to the
# ordinary install.

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

message("Installing the duckdb binary from ", repo)
tryCatch(
  {
    install.packages("duckdb", repos = repo)
    message("duckdb ", format(packageVersion("duckdb")), " installed")
  },
  error = function(e) message("No duckdb binary: ", conditionMessage(e))
)
