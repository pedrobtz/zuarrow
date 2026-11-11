# Helpers of test-utf8.R: the validator's verdicts, the oracle's, and
# the cases of Kuhn's stress test.

# The validator's verdict on each byte sequence, through the full level of
# arrow_validate()'s entry point without its condition, which the loop
# would pay for 50 000 times.
utf8_verdicts <- function(sequences) {
  schema <- arrow_schema("u")
  vapply(
    sequences,
    function(bytes) {
      array <- .Call(
        zuarrow:::zar_c_array_from_buffers,
        schema,
        test_array_spec(
          1,
          list(NULL, le_int(c(0L, length(bytes)), 4L), bytes)
        )
      )
      isTRUE(.Call(zuarrow:::zar_c_array_validate, array, 3L))
    },
    logical(1)
  )
}

oracle_verdicts <- function(sequences) {
  vapply(sequences, function(b) validUTF8(rawToChar(b)), logical(1))
}

# The sequences where the validator and the oracle disagree, in hex, so a
# failure names them.
utf8_disagreements <- function(sequences) {
  sequences <- gctorture_sample(sequences, 200L)
  ours <- utf8_verdicts(sequences)
  theirs <- oracle_verdicts(sequences)
  bad <- sequences[ours != theirs]
  vapply(bad, function(b) paste(as.character(b), collapse = " "), "")
}

# Every combination of one byte from each vector, as raw sequences.
byte_product <- function(...) {
  grid <- as.matrix(expand.grid(list(...), KEEP.OUT.ATTRS = FALSE))
  lapply(seq_len(nrow(grid)), function(i) as.raw(grid[i, ]))
}

# Markus Kuhn's UTF-8 decoder stress test (UTF-8-test.txt, 2015-08-28), its
# cases written out by number. Each is valid or not under RFC 3629: the
# five- and six-byte forms of section 2, everything in sections 3 and 4,
# and the surrogates of 5.1 and 5.2 are not; the noncharacters of 5.3 are.
kuhn_cases <- function() {
  h <- function(x) as.raw(strtoi(strsplit(x, " ")[[1]], 16L))
  cont <- function(n) as.raw(rep(c(0x80, 0xbf), length.out = n))
  lonely <- function(leads) as.raw(c(rbind(leads, 0x20)))
  missing <- c(
    "3.3.1" = "c0",
    "3.3.2" = "e0 80",
    "3.3.3" = "f0 80 80",
    "3.3.4" = "f8 80 80 80",
    "3.3.5" = "fc 80 80 80 80",
    "3.3.6" = "df",
    "3.3.7" = "ef bf",
    "3.3.8" = "f7 bf bf",
    "3.3.9" = "fb bf bf bf",
    "3.3.10" = "fd bf bf bf bf"
  )
  nonchar <- unlist(lapply(1:16, function(n) n * 65536 + c(65534, 65535)))
  valid <- list(
    "1" = charToRaw("\u03ba\u1f79\u03c3\u03bc\u03b5"),
    "2.1.2" = h("c2 80"),
    "2.1.3" = h("e0 a0 80"),
    "2.1.4" = h("f0 90 80 80"),
    "2.2.1" = h("7f"),
    "2.2.2" = h("df bf"),
    "2.2.3" = h("ef bf bf"),
    "2.3.1" = h("ed 9f bf"),
    "2.3.2" = h("ee 80 80"),
    "2.3.3" = h("ef bf bd"),
    "2.3.4" = h("f4 8f bf bf"),
    "5.3.1" = h("ef bf be"),
    "5.3.2" = h("ef bf bf"),
    "5.3.3" = charToRaw(intToUtf8(0xfdd0:0xfdef)),
    "5.3.4" = charToRaw(intToUtf8(nonchar))
  )
  invalid <- c(
    list(
      "2.1.5" = h("f8 88 80 80 80"),
      "2.1.6" = h("fc 84 80 80 80 80"),
      "2.2.4" = h("f7 bf bf bf"),
      "2.2.5" = h("fb bf bf bf bf"),
      "2.2.6" = h("fd bf bf bf bf bf"),
      "2.3.5" = h("f4 90 80 80"),
      "3.1.1" = h("80"),
      "3.1.2" = h("bf"),
      "3.1.3" = cont(2),
      "3.1.4" = cont(3),
      "3.1.5" = cont(4),
      "3.1.6" = cont(5),
      "3.1.7" = cont(6),
      "3.1.8" = cont(7),
      "3.1.9" = as.raw(0x80:0xbf),
      "3.2.1" = lonely(0xc0:0xdf),
      "3.2.2" = lonely(0xe0:0xef),
      "3.2.3" = lonely(0xf0:0xf7),
      "3.2.4" = lonely(0xf8:0xfb),
      "3.2.5" = lonely(0xfc:0xfd)
    ),
    lapply(missing, h),
    list(
      "3.4" = unlist(lapply(missing, h), use.names = FALSE),
      "3.5.1" = h("fe"),
      "3.5.2" = h("ff"),
      "3.5.3" = h("fe fe ff ff"),
      "4.1.1" = h("c0 af"),
      "4.1.2" = h("e0 80 af"),
      "4.1.3" = h("f0 80 80 af"),
      "4.1.4" = h("f8 80 80 80 af"),
      "4.1.5" = h("fc 80 80 80 80 af"),
      "4.2.1" = h("c1 bf"),
      "4.2.2" = h("e0 9f bf"),
      "4.2.3" = h("f0 8f bf bf"),
      "4.2.4" = h("f8 87 bf bf bf"),
      "4.2.5" = h("fc 83 bf bf bf bf"),
      "4.3.1" = h("c0 80"),
      "4.3.2" = h("e0 80 80"),
      "4.3.3" = h("f0 80 80 80"),
      "4.3.4" = h("f8 80 80 80 80"),
      "4.3.5" = h("fc 80 80 80 80 80"),
      "5.1.1" = h("ed a0 80"),
      "5.1.2" = h("ed ad bf"),
      "5.1.3" = h("ed ae 80"),
      "5.1.4" = h("ed af bf"),
      "5.1.5" = h("ed b0 80"),
      "5.1.6" = h("ed be 80"),
      "5.1.7" = h("ed bf bf"),
      "5.2.1" = h("ed a0 80 ed b0 80"),
      "5.2.2" = h("ed a0 80 ed bf bf"),
      "5.2.3" = h("ed ad bf ed b0 80"),
      "5.2.4" = h("ed ad bf ed bf bf"),
      "5.2.5" = h("ed ae 80 ed b0 80"),
      "5.2.6" = h("ed ae 80 ed bf bf"),
      "5.2.7" = h("ed af bf ed b0 80"),
      "5.2.8" = h("ed af bf ed bf bf")
    )
  )
  list(valid = valid, invalid = invalid)
}
