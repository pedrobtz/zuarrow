# The gctorture.yaml caller sets ZUARROW_GCTORTURE=true.
under_gctorture <- function() {
  identical(Sys.getenv("ZUARROW_GCTORTURE"), "true")
}

# testthat's skip_on_cran() test: CI sets NOT_CRAN=true.
on_cran <- function() {
  !identical(Sys.getenv("NOT_CRAN"), "true")
}

# Under gctorture, a loop that repeats one path runs a fixed sample of it:
# gctorture finds an unprotected SEXP by running the path that holds it, not
# by running it again. The sample is n elements spread evenly over x, the
# same on every run. With `cran`, CRAN runs a sample of that size too, to
# keep the suite inside its time budget. Everywhere else x is returned
# whole.
gctorture_sample <- function(x, n, cran = NULL) {
  if (!under_gctorture() && !is.null(cran) && on_cran()) {
    n <- cran
  } else if (!under_gctorture()) {
    return(x)
  }
  if (length(x) <= n) {
    return(x)
  }
  x[unique(round(seq(1, length(x), length.out = n)))]
}
