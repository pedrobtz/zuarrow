# zar_utf8.c's strict validator against an independent decoder: base R's
# validUTF8(), which also refuses overlong forms, surrogates and code points
# past U+10FFFF (RFC 3629). R strings cannot hold a NUL byte, so the
# differential leaves 0x00 out; the NUL cases are asserted by hand.

test_that("the validator and validUTF8() agree on every 1-byte sequence", {
  expect_identical(utf8_disagreements(byte_product(1:255)), character())
  expect_true(utf8_verdicts(list(as.raw(0))))
})

test_that("they agree on every 2-byte sequence with a non-ASCII lead", {
  skip_on_cran()
  # After an ASCII byte the verdict is the second byte's own, which the
  # 1-byte case covers; three ASCII leads check that it is.
  sequences <- byte_product(c(0x01, 0x41, 0x7f, 0x80:0xff), 1:255)
  expect_identical(utf8_disagreements(sequences), character())
})

test_that("they agree on 3- and 4-byte sequences around every edge", {
  # Every lead of a 3- or 4-byte form, every second byte from just below
  # the continuations to just past them (the E0, ED, F0 and F4 leads narrow
  # that range), and the edges of the continuation range after it.
  edge <- c(0x7f, 0x80, 0xbf, 0xc0)
  three <- byte_product(0xe0:0xef, 0x7f:0xc0, edge)
  four <- byte_product(0xf0:0xf7, 0x7f:0xc0, edge, c(0x80, 0xbf, 0xc0))
  expect_identical(utf8_disagreements(three), character())
  expect_identical(utf8_disagreements(four), character())
})

test_that("they agree on random sequences of lead and continuation bytes", {
  withr::local_seed(20261111)
  pool <- c(0x01:0x7f, 0x80:0xbf, 0x80:0xbf, 0xc0:0xff, 0xe0:0xf4)
  sequences <- lapply(
    sample(c(3L, 4L, 5L, 8L, 9L, 12L), 2000L, replace = TRUE),
    function(n) as.raw(sample(pool, n, replace = TRUE))
  )
  expect_identical(utf8_disagreements(sequences), character())
})

test_that("Kuhn's stress test cases get their RFC 3629 verdict", {
  cases <- kuhn_cases()
  verdicts <- function(x) names(x)[!utf8_verdicts(x)]
  expect_identical(verdicts(cases$valid), character())
  expect_identical(
    names(cases$invalid)[utf8_verdicts(cases$invalid)],
    character()
  )
  # 2.1.1, U+0000, is valid UTF-8; R strings cannot hold it.
  expect_true(utf8_verdicts(list(as.raw(0))))
  # The oracle reaches the same verdicts, so the cases are written right.
  expect_true(all(oracle_verdicts(cases$valid)))
  expect_false(any(oracle_verdicts(cases$invalid)))
})

test_that("a valid sequence fails once its bytes are cut or followed", {
  # The fast path reads eight ASCII bytes at a time, so a multi-byte form
  # is placed at every position modulo eight.
  forms <- list(
    as.raw(c(0xc2, 0x80)),
    as.raw(c(0xe0, 0xa0, 0x80)),
    as.raw(c(0xf4, 0x8f, 0xbf, 0xbf))
  )
  sequences <- list()
  for (form in forms) {
    for (pad in 0:8) {
      ascii <- rep(as.raw(0x61), pad)
      sequences <- c(
        sequences,
        list(
          c(ascii, form),
          c(ascii, form, ascii),
          c(ascii, form[-length(form)], ascii),
          c(ascii, form, as.raw(0x80), ascii)
        )
      )
    }
  }
  expect_identical(utf8_disagreements(sequences), character())
})
