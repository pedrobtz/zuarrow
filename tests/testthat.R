# This file is part of the standard setup for testthat.
# It is recommended that you do not modify it.
#
# Where should you do additional test configuration?
# Learn more about the roles of various files in:
# * https://r-pkgs.org/testing-design.html#sec-tests-files-overview
# * https://testthat.r-lib.org/articles/special-files.html
#
# Modified for zuarrow: testthat is in Suggests, and CRAN's NOSUGGESTS check
# runs this file without it, so the suite runs only when it is installed.

if (requireNamespace("testthat", quietly = TRUE)) {
  library(testthat)
  library(zuarrow)

  test_check("zuarrow")
}
