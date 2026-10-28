# Random values of every built-in exact type, with a fifth of them NA (or
# NULL, for a list). Any n from 0 up works.
random_values <- function(kind, n) {
  values <- switch(
    kind,
    logical = sample(c(TRUE, FALSE), n, TRUE),
    integer = sample.int(.Machine$integer.max, n, TRUE) *
      sample(c(-1L, 1L), n, TRUE),
    double = {
      v <- stats::rnorm(n) * 10^sample(-300:300, n, TRUE)
      # NaN and -0 where there is room: both must survive as values.
      specials <- c(NaN, -0)[seq_len(min(n, 2L))]
      v[seq_along(specials)] <- specials
      v
    },
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
    }),
    factor = factor(
      sample(c("a", "b", "\u00e9"), n, TRUE),
      levels = c("\u00e9", "b", "a")
    ),
    ordered = factor(
      sample(c("lo", "mid", "hi"), n, TRUE),
      levels = c("lo", "mid", "hi"),
      ordered = TRUE
    ),
    list = lapply(seq_len(n), function(i) {
      random_values("integer", sample(0:4, 1))
    }),
    frames = lapply(seq_len(n), function(i) {
      rows <- sample(0:3, 1)
      data.frame(
        a = random_values("integer", rows),
        b = random_values("character", rows)
      )
    }),
    struct = data.frame(
      a = random_values("double", n),
      b = random_values("factor", n)
    )
  )
  if (is.data.frame(values)) {
    return(values)
  }
  nulls <- sample(seq_len(n), n %/% 5)
  if (is.list(values)) {
    values[nulls] <- list(NULL)
  } else {
    values[nulls] <- NA
  }
  values
}
