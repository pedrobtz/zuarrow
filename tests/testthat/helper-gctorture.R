# The gctorture.yaml caller sets ZUARROW_GCTORTURE=true.
under_gctorture <- function() {
  identical(Sys.getenv("ZUARROW_GCTORTURE"), "true")
}

# Under gctorture, a loop that repeats one path runs a fixed sample of it:
# gctorture finds an unprotected SEXP by running the path that holds it, not
# by running it again. The sample is n elements spread evenly over x, the
# same on every run. Everywhere else x is returned whole.
gctorture_sample <- function(x, n) {
  if (!under_gctorture() || length(x) <= n) {
    return(x)
  }
  x[unique(round(seq(1, length(x), length.out = n)))]
}
