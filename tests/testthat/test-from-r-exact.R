# R values that would not export exactly are refused (design section 6.3).

test_that("a non-ASCII native string is refused in a C locale (#203)", {
  local_ctype(c("C", "POSIX"))
  skip_if(l10n_info()[["UTF-8"]], "the C locale is UTF-8 here")
  for (s in c("\xc3\xa9", "\xff\xfe")) {
    routes <- export_routes(s)
    for (route in names(routes)) {
      expect_error(
        routes[[route]](),
        class = "zuarrow_type_error",
        info = route
      )
    }
  }
  # Marked strings are exact in any locale.
  utf8 <- "caf\u00e9"
  expect_identical(charToRaw(arrow_to_r(arrow_array(utf8))), charToRaw(utf8))
  latin1 <- iconv(utf8, "UTF-8", "latin1")
  expect_identical(charToRaw(arrow_to_r(arrow_array(latin1))), charToRaw(utf8))
})

test_that("a native string is read as UTF-8 in a UTF-8 locale (#203)", {
  local_ctype(c("C.UTF-8", "en_US.UTF-8", "en_US.utf8", "C.utf8"))
  s <- "\xc3\xa9"
  expect_identical(charToRaw(arrow_to_r(arrow_array(s))), charToRaw(s))
  back <- arrow_read(arrow_write(data.frame(x = s), NULL))$x
  expect_identical(charToRaw(back), charToRaw(s))
  expect_identical(
    charToRaw(levels(arrow_to_r(arrow_array(factor(s))))),
    charToRaw(s)
  )
  schema <- arrow_schema("i")
  arrow_metadata(schema) <- c(k = s)
  expect_identical(charToRaw(arrow_metadata(schema)[["k"]]), charToRaw(s))
  routes <- export_routes("\xff\xfe")
  for (route in names(routes)) {
    expect_error(routes[[route]](), class = "zuarrow_type_error", info = route)
  }
})

test_that("a matrix needs a list schema and an unclassed item (#209)", {
  m <- matrix(1:6, 3)
  expect_error(arrow_array(m, schema = "i"), class = "zuarrow_type_error")
  d <- data.frame(a = 1:3)
  d$m <- m
  schema <- arrow_schema(data.frame(a = 1L, m = 1L))
  expect_error(arrow_stream(d, schema = schema), class = "zuarrow_type_error")
  expect_error(arrow_array(d, schema = schema), class = "zuarrow_type_error")
  classed <- list(
    structure(c(1, 2, 3, 4), dim = c(2L, 2L), class = "Date"),
    structure(c(1, 2, 3, 4), dim = c(2L, 2L), class = c("POSIXct", "POSIXt")),
    structure(
      c(1L, 2L, 1L, 2L),
      dim = c(2L, 2L),
      levels = c("a", "b"),
      class = "factor"
    )
  )
  df_schema <- test_schema(zspec(
    "+s",
    children = list(
      zspec("i", "a"),
      zspec("+w:2", "m", children = list(zspec("g", "item")))
    )
  ))
  for (x in classed) {
    expect_error(
      arrow_array(x, schema = arrow_matrix()),
      class = "zuarrow_type_error"
    )
    df <- data.frame(a = 1:2)
    df$m <- x
    expect_error(
      arrow_array(df, schema = df_schema),
      class = "zuarrow_type_error"
    )
  }
  # A plain matrix still writes as a fixed_size_list.
  expect_identical(
    arrow_to_r(arrow_array(m, schema = arrow_matrix()), to = arrow_matrix()),
    m
  )
})

test_that("fixed_size_binary round-trips through arrow_width (#210)", {
  array <- arrow_array(list(as.raw(1:2), NULL, as.raw(3:4)), schema = "w:2")
  r <- arrow_to_r(array)
  expect_identical(format(arrow_schema(r)), format(arrow_schema(array)))
  expect_true(arrow_equal(arrow_array(r), array))
  df <- data.frame(id = 1:3)
  df$x <- r
  back <- arrow_read(arrow_write(df, NULL))
  expect_identical(attr(back$x, "arrow_width"), 2L)
  expect_identical(back, df)
  # Under an extension type the width is kept too.
  uuid <- test_array(
    ext_schema("w:16", "arrow.uuid"),
    1,
    list(NULL, as.raw(1:16))
  )
  r <- arrow_to_r(uuid)
  expect_true(arrow_equal(arrow_array(r), uuid))
  # An element of another length, or a bad width, is refused.
  wrong <- structure(list(as.raw(1:2), as.raw(1:3)), arrow_width = 2L)
  expect_error(arrow_array(wrong), class = "zuarrow_type_error")
  for (width in list(0L, -1L, NA_integer_, 1.5, "2", c(2L, 2L))) {
    bad <- structure(list(as.raw(1:2)), arrow_width = width)
    expect_error(arrow_array(bad), class = "zuarrow_type_error")
  }
})

test_that("a factor with an NA level is refused (#211)", {
  f <- factor(c("a", NA, "b"), exclude = NULL)
  expect_error(arrow_array(f), class = "zuarrow_type_error")
  err <- expect_error(
    arrow_array(data.frame(f = f)),
    class = "zuarrow_type_error"
  )
  expect_identical(err$column, "f")
  expect_error(
    arrow_stream(data.frame(f = f), batch = 1),
    class = "zuarrow_type_error"
  )
  expect_error(
    arrow_write(data.frame(f = f), NULL),
    class = "zuarrow_type_error"
  )
  expect_error(arrow_array(f, schema = "u"), class = "zuarrow_type_error")
  # An NA value without an NA level is a null, as before.
  g <- factor(c("a", NA, "b"))
  expect_identical(arrow_to_r(arrow_array(g)), g)
})

test_that("extension metadata, tzone and units are checked (#214)", {
  ext <- function(metadata) {
    structure(
      1:2,
      arrow_extension = "my.ext",
      arrow_extension_metadata = metadata
    )
  }
  for (metadata in list(NA_character_, c("a", "b"), 5, character(), list())) {
    expect_error(arrow_array(ext(metadata)), class = "zuarrow_type_error")
  }
  expect_error(
    arrow_array(structure(1:2, arrow_extension_metadata = "m")),
    class = "zuarrow_type_error"
  )
  ok <- arrow_array(ext("m"))
  expect_identical(
    attr(arrow_to_r(ok), "arrow_extension_metadata"),
    "m"
  )
  expect_true(arrow_equal(arrow_array(ext(charToRaw("m"))), ok))

  posix <- function(tz) structure(1, class = c("POSIXct", "POSIXt"), tzone = tz)
  for (tz in list(NA_character_, 5, character(), TRUE)) {
    expect_error(arrow_array(posix(tz)), class = "zuarrow_type_error")
    expect_error(
      arrow_array(posix(tz), schema = "tsu:UTC"),
      class = "zuarrow_type_error"
    )
  }
  expect_error(
    arrow_array(list(
      as.POSIXct(1, tz = "UTC"),
      as.POSIXct(2, tz = "Asia/Tokyo")
    )),
    class = "zuarrow_type_error"
  )
  same <- list(
    as.POSIXct(1, tz = "Asia/Tokyo"),
    as.POSIXct(2, tz = "Asia/Tokyo")
  )
  expect_identical(
    attr(arrow_to_r(arrow_array(same))[[1L]], "tzone"),
    "Asia/Tokyo"
  )

  units <- function(u) structure(1, class = "difftime", units = u)
  for (u in list(
    "fortnights",
    "auto",
    "",
    NA_character_,
    c("secs", "mins"),
    1
  )) {
    expect_error(arrow_array(units(u)), class = "zuarrow_type_error")
    expect_error(
      arrow_array(units(u), schema = "tDs"),
      class = "zuarrow_type_error"
    )
  }
  expect_error(
    arrow_array(structure(1, class = "difftime")),
    class = "zuarrow_type_error"
  )
  expect_identical(
    as.vector(arrow_to_r(
      arrow_array(units("weeks"), schema = "tDs"),
      to = character()
    )),
    "604800"
  )
})

test_that("data frame elements bind whatever their row names (#217)", {
  d1 <- data.frame(a = 1:2)
  d1$s <- data.frame(q = c("a", "b"))
  x <- list(d1, d1[2, , drop = FALSE])
  out <- arrow_to_r(arrow_array(x))
  expect_identical(out[[2L]]$a, 2L)
  expect_identical(out[[2L]]$s$q, "b")
  named <- data.frame(a = 1:2, row.names = c("x", "y"))
  out <- arrow_to_r(arrow_array(list(named, named)))
  expect_identical(lapply(out, `[[`, "a"), list(1:2, 1:2))
})

test_that("a non-finite batch or an out-of-range level is refused (#219)", {
  df <- data.frame(a = 1:5)
  for (batch in c(Inf, -Inf, NaN)) {
    expect_error(arrow_stream(df, batch = batch), class = "zuarrow_type_error")
    expect_error(
      arrow_write(df, NULL, batch = batch),
      class = "zuarrow_type_error"
    )
  }
  for (level in c(Inf, -Inf, NaN, 2^31, -2^31 - 1)) {
    for (compression in c("none", "lz4", "zstd")) {
      expect_error(
        arrow_write(df, NULL, compression = compression, level = level),
        class = "zuarrow_type_error"
      )
    }
  }
})
