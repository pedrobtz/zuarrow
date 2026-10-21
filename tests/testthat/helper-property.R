# Random values of every built-in exact type, with a fifth of them NA.
random_values <- function(kind, n) {
  values <- switch(
    kind,
    logical = sample(c(TRUE, FALSE), n, TRUE),
    integer = sample.int(.Machine$integer.max, n, TRUE) *
      sample(c(-1L, 1L), n, TRUE),
    double = c(
      stats::rnorm(n - 2L) * 10^sample(-300:300, n - 2L, TRUE),
      NaN,
      -0
    ),
    character = vapply(
      seq_len(n),
      function(i) {
        intToUtf8(sample(
          c(32:126, 0xe9, 0x4e2d, 0x1f600),
          sample(0:12, 1),
          TRUE
        ))
      },
      ""
    ),
    Date = as.Date(sample(-100000:100000, n, TRUE)),
    blob = lapply(seq_len(n), function(i) {
      as.raw(sample(0:255, sample(0:8, 1), TRUE))
    })
  )
  nulls <- sample(n, n %/% 5)
  if (is.list(values)) {
    values[nulls] <- list(NULL)
  } else {
    values[nulls] <- NA
  }
  values
}
