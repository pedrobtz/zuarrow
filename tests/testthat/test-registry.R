# The registry, design section 6.10. A test-only registration stands in for
# a typed package such as zuint.

test_that("a registration makes a lossy type exact", {
  local_registration("l", to = as_text_int64)
  big <- test_array("l", 1, list(NULL, le_hex("0020000000000001")))
  out <- arrow_to_r(big)
  expect_s3_class(out, "fake_int64")
  expect_identical(unclass(out), "9007199254740993")
})

test_that("a registered handler converts each batch, combined with c()", {
  local_registration("l", to = as_text_int64)
  stream <- test_stream(
    "l",
    list(test_fixed("l", 1, 8L), test_fixed("l", c(2, 3), 8L))
  )
  expect_identical(unclass(arrow_to_r(stream)), c("1", "2", "3"))
})

test_that("handlers convert data frame columns", {
  local_registration("l", to = as_text_int64)
  schema <- test_schema(zspec(
    "+s",
    children = list(zspec("l", "id"), zspec("i", "n"))
  ))
  batch <- test_array(
    schema,
    2,
    list(NULL),
    children = list(
      test_array_spec(2, list(NULL, le_int(c(5, 6), 8L))),
      test_array_spec(2, list(NULL, le_int(c(1, 2), 4L)))
    )
  )
  out <- arrow_to_r(batch)
  expect_s3_class(out$id, "fake_int64")
  expect_identical(out$n, 1:2)
})

test_that("a stream with no batches calls the handler on an empty array", {
  local_registration("l", to = as_text_int64)
  out <- arrow_to_r(test_stream(
    test_schema(zspec("+s", children = list(zspec("l", "id")))),
    list()
  ))
  expect_identical(nrow(out), 0L)
  expect_s3_class(out$id, "fake_int64")
})

test_that("patterns match prefixes, extension names take precedence", {
  local_registration("d:*", to = function(array, schema) {
    rep("pattern", arrow_info_length(array))
  })
  local_registration("my.ext", to = function(array, schema) {
    rep("extension", arrow_info_length(array))
  })
  expect_identical(arrow_to_r(test_fixed("d:5,2", 1, 16L)), "pattern")
  schema <- test_schema(list(
    format = "d:5,2",
    name = "",
    flags = 2L,
    metadata = list("ARROW:extension:name" = charToRaw("my.ext")),
    children = list(),
    dictionary = NULL
  ))
  expect_identical(
    arrow_to_r(test_array(schema, 1, list(NULL, le_int(1, 16L)))),
    "extension"
  )
})

test_that("from converts a registered class to Arrow", {
  local_registration(
    "l",
    to = as_text_int64,
    from = function(x) arrow_array(structure(unclass(x), arrow_type = "l")),
    class = "fake_int64"
  )
  x <- structure(c("9007199254740993", "1"), class = "fake_int64")
  array <- arrow_array(x)
  expect_identical(format_of(arrow_schema(array)), "l")
  expect_identical(unclass(arrow_to_r(array)), unclass(x))

  df <- data.frame(n = 1:2)
  df$id <- x
  back <- as.data.frame(arrow_stream(df, batch = 1))
  expect_identical(unclass(back$id), unclass(x))
  expect_identical(back$n, 1:2)
})

test_that("an inexact registration applies only under warn and allow", {
  local_registration(
    "tsn:*",
    to = function(array, schema) rep(0, arrow_info_length(array)),
    exact = FALSE
  )
  ns <- test_fixed("tsn:UTC", 1, 8L)
  expect_error(arrow_to_r(ns), class = "zuarrow_lossy_error")
  expect_identical(arrow_to_r(ns, lossy = "allow"), 0)
  expect_warning(
    arrow_to_r(ns, lossy = "warn"),
    class = "zuarrow_lossy_warning"
  )
})

test_that("a registration may not make an exact type lossy", {
  expect_error(
    arrow_register("i", to = function(a, s) 1, exact = FALSE),
    class = "zuarrow_registry_error"
  )
  expect_error(
    arrow_register("u", to = function(a, s) 1, exact = FALSE),
    class = "zuarrow_registry_error"
  )
  expect_error(
    arrow_register("arrow.bool8", to = function(a, s) 1, exact = FALSE),
    class = "zuarrow_registry_error"
  )
  exact <- c(
    "tss:",
    "tsm:UTC",
    "tsu:UTC",
    "tsu:*",
    "+w:4",
    "+vl",
    "+vL",
    "tss:*",
    "tsm*",
    "+v*"
  )
  for (key in exact) {
    expect_error(
      arrow_register(key, to = function(a, s) 1, exact = FALSE),
      class = "zuarrow_registry_error",
      info = key
    )
  }
  # Lossy defaults may still take an inexact registration.
  for (key in c("tsn:UTC", "tsn:*", "tdm")) {
    local_registration(key, to = function(a, s) 1, exact = FALSE)
    expect_true(key %in% arrow_registry()$key, info = key)
  }
})

test_that("malformed registrations are registry errors", {
  expect_error(
    arrow_register("", to = function(a, s) 1),
    class = "zuarrow_registry_error"
  )
  expect_error(arrow_register("l"), class = "zuarrow_registry_error")
  expect_error(arrow_register("l", to = 1), class = "zuarrow_registry_error")
  expect_error(
    arrow_register("l", to = function(a) 1),
    class = "zuarrow_registry_error"
  )
  expect_error(
    arrow_register("l", from = function(x) x),
    class = "zuarrow_registry_error"
  )
  expect_error(
    arrow_register("l", to = function(a, s) 1, class = "x"),
    class = "zuarrow_registry_error"
  )
  expect_error(
    arrow_register("l", to = function(a, s) 1, exact = NA),
    class = "zuarrow_registry_error"
  )
})

test_that("a missing package is a dependency error", {
  expect_error(
    arrow_register("l", to = function(a, s) 1, package = "zuarrowNotAPackage"),
    class = "zuarrow_dependency_error"
  )
})

test_that("a later registration replaces the earlier one with a message", {
  local_unload_hooks(c("stats", "utils"))
  local_registration("l", to = as_text_int64, package = "utils")
  # The message names both packages.
  expect_snapshot(arrow_register("l", to = as_text_int64, package = "stats"))
  expect_identical(
    arrow_registry()$package[arrow_registry()$key == "l"],
    "stats"
  )
})

test_that("arrow_registry() lists key, kind, class, package and exact", {
  local_registration(
    "l",
    to = as_text_int64,
    from = function(x) x,
    class = "fake_int64"
  )
  local_registration("tsn:*", to = as_text_int64)
  reg <- arrow_registry()
  expect_named(reg, c("key", "kind", "class", "package", "exact"))
  expect_identical(
    reg$kind[match(c("l", "tsn:*"), reg$key)],
    c("format", "pattern")
  )
  expect_identical(reg$class[reg$key == "l"], "fake_int64")
})

test_that("a package's registrations are removed when it unloads", {
  local_unload_hooks("stats")
  event <- packageEvent("stats", "onUnload")
  # Clear zuarrow's record so the hook is added afresh, and run only it.
  registry <- zuarrow:::zar_registry
  registry$hooked <- character()
  before <- length(getHook(event))
  arrow_register("l", to = as_text_int64, package = "stats")
  withr::defer(arrow_unregister("l"))
  expect_true("l" %in% arrow_registry()$key)
  hooks <- getHook(event)
  added <- hooks[seq_along(hooks) > before]
  expect_length(added, 1L)
  added[[1L]]("stats")
  expect_false("l" %in% arrow_registry()$key)
})

test_that("a handler that returns the wrong length is a registry error", {
  local_registration("l", to = function(array, schema) 1:5)
  expect_error(
    arrow_to_r(test_fixed("l", 1, 8L)),
    class = "zuarrow_registry_error"
  )
})

test_that("handlers convert the fields of nested data frames", {
  local_registration("l", to = as_text_int64)
  inner <- zspec("+s", "s", children = list(zspec("l", "b"), zspec("i", "c")))
  outer <- zspec("+s", "t", children = list(zspec("l", "d")))
  schema <- test_schema(zspec(
    "+s",
    children = list(zspec("l", "a"), inner, zspec("+s", "u", list(outer)))
  ))
  make <- function() {
    test_array(
      schema,
      2,
      list(NULL),
      children = list(
        test_array_spec(2, list(NULL, le_int(c(1, 2), 8L))),
        test_array_spec(
          2,
          list(as.raw(0x01)),
          null_count = 1,
          children = list(
            test_array_spec(2, list(NULL, le_int(c(3, 4), 8L))),
            test_array_spec(2, list(NULL, le_int(c(5, 6), 4L)))
          )
        ),
        test_array_spec(
          2,
          list(as.raw(0x01)),
          null_count = 1,
          children = list(test_array_spec(
            2,
            list(NULL),
            children = list(test_array_spec(2, list(NULL, le_int(c(7, 8), 8L))))
          ))
        )
      )
    )
  }
  out <- arrow_to_r(make())
  expect_s3_class(out$a, "fake_int64")
  expect_s3_class(out$s$b, "fake_int64")
  # Row 2 of `s` is null, so its fields are NA.
  expect_identical(unclass(out$s$b), c("3", NA))
  expect_identical(out$s$c, c(5L, NA))
  expect_s3_class(out$u$t$d, "fake_int64")
  # Row 2 of `u` is null, so the fields of `t` within it are NA too.
  expect_identical(unclass(out$u$t$d), c("7", NA))

  stream <- test_stream(schema, list(make(), make()))
  out <- arrow_to_r(stream)
  expect_identical(unclass(out$s$b), c("3", NA, "3", NA))
})

test_that("handlers do not apply to the items of a list column", {
  local_registration("l", to = as_text_int64)
  df <- data.frame(i = 1:2)
  df$l <- list(c(1, 2), 3)
  array <- arrow_array(
    df,
    schema = test_schema(zspec(
      "+s",
      children = list(
        zspec("i", "i"),
        zspec("+l", "l", list(zspec("l", "item")))
      )
    ))
  )
  out <- arrow_to_r(array)
  expect_identical(out$l, list(c(1, 2), 3))
})

test_that("a nested data frame converted for a handler matches the built-in", {
  df <- data.frame(id = 1:3)
  df$s <- data.frame(x = c(1.5, NA, 3), y = c("a", "b", NA))
  df$s$t <- data.frame(z = 4:6)
  expected <- arrow_to_r(arrow_stream(df, batch = 2L))
  local_registration("i", to = function(array, schema) arrow_to_r(array))
  expect_identical(arrow_to_r(arrow_stream(df, batch = 2L)), expected)
})

test_that("conditions from a handled nested field name its path", {
  df <- data.frame(id = 1L)
  df$s <- data.frame(c = 1L, b = 2^53 + 2)
  schema <- test_schema(zspec(
    "+s",
    children = list(
      zspec("i", "id"),
      zspec("+s", "s", children = list(zspec("i", "c"), zspec("l", "b")))
    )
  ))
  array <- arrow_array(df, schema = schema)

  # An exact handler on `c` converts `s` in R, field by field.
  local_registration("i", to = function(array, schema) arrow_to_r(array))
  err <- expect_error(arrow_to_r(array), class = "zuarrow_lossy_error")
  expect_identical(err$column, "s$b")
  expect_snapshot(arrow_to_r(array), error = TRUE)
  w <- expect_warning(
    arrow_to_r(array, lossy = "warn"),
    class = "zuarrow_lossy_warning"
  )
  expect_identical(w$column, "s$b")

  # An inexact handler on `b` itself warns under its path too.
  local_registration("l", to = as_text_int64, exact = FALSE)
  w <- expect_warning(
    arrow_to_r(array, lossy = "warn"),
    class = "zuarrow_lossy_warning"
  )
  expect_identical(w$column, "s$b")
})

test_that("a from handler's array must match the schema's type and length", {
  x <- structure(1:2, class = "fake_int")
  local_registration(
    "i",
    from = function(x) arrow_array(unclass(x)),
    class = "fake_int"
  )
  expect_error(arrow_array(x, schema = "l"), class = "zuarrow_registry_error")
  arrow_unregister("i")
  local_registration(
    "i",
    from = function(x) arrow_array(1:5),
    class = "fake_int"
  )
  expect_error(arrow_array(x, schema = "i"), class = "zuarrow_registry_error")
  expect_error(
    arrow_array(data.frame(v = 1, w = I(x))),
    class = "zuarrow_registry_error"
  )
})

test_that("more than 256 registered columns is a limit error", {
  local_registration(
    "i",
    from = function(x) arrow_array(unclass(x)),
    class = "fake_int"
  )
  column <- structure(1L, class = "fake_int")
  fits <- as.data.frame(
    rep(list(I(column)), 256L),
    col.names = paste0("c", 1:256)
  )
  expect_s3_class(arrow_array(fits), "zuarrow_array")
  past <- as.data.frame(
    rep(list(I(column)), 257L),
    col.names = paste0("c", 1:257)
  )
  expect_error(arrow_array(past), class = "zuarrow_limit_error")
})

test_that("a three-argument to handler receives the lossy policy", {
  local_registration("l", to = function(array, schema, lossy) {
    rep(lossy, arrow_info_length(array))
  })
  big <- test_fixed("l", 1, 8L)
  for (lossy in c("error", "character", "warn", "allow")) {
    expect_identical(arrow_to_r(big, lossy = lossy), lossy)
  }
  local_registration("L", to = function(array, schema) {
    rep("two", arrow_info_length(array))
  })
  expect_identical(arrow_to_r(test_fixed("L", 1, 8L)), "two")
  local_registration("i", to = function(...) {
    rep(as.character(...length()), arrow_info_length(..1))
  })
  expect_identical(arrow_to_r(test_fixed("i", 1, 4L)), "3")
})

test_that("a to handler that needs more than three arguments is refused", {
  expect_error(
    arrow_register("l", to = function(array, schema, lossy, extra) 1),
    class = "zuarrow_registry_error"
  )
  expect_false("l" %in% arrow_registry()$key)
  local_registration(
    "l",
    to = function(array, schema, lossy, extra = NULL) {
      rep("ok", arrow_info_length(array))
    }
  )
  expect_identical(arrow_to_r(test_fixed("l", 1, 8L)), "ok")
})

test_that("an extension name beats an exact format, which beats a pattern", {
  tagged <- function(tag) {
    function(array, schema) rep(tag, arrow_info_length(array))
  }
  # Registered in the reverse of their precedence, so the order of
  # registration cannot be what decides.
  local_registration("my.ext", to = tagged("extension"))
  local_registration("d:5,2", to = tagged("format"))
  local_registration("d:*", to = tagged("pattern"))
  expect_identical(arrow_to_r(test_fixed("d:5,2", 1, 16L)), "format")
  expect_identical(arrow_to_r(test_fixed("d:38,0", 1, 16L)), "pattern")
  schema <- test_schema(list(
    format = "d:5,2",
    name = "",
    flags = 2L,
    metadata = list("ARROW:extension:name" = charToRaw("my.ext")),
    children = list(),
    dictionary = NULL
  ))
  expect_identical(
    arrow_to_r(test_array(schema, 1, list(NULL, le_int(1, 16L)))),
    "extension"
  )
})

test_that("a prototype of a registered class in `to` selects its handler", {
  # The opt-in for a d:38,0 column that holds integers: it stays a decimal
  # by its schema, and `to` names the class that reads it otherwise.
  local_registration(
    "fake.int128",
    to = function(array, schema) {
      structure(rep("int128", arrow_info_length(array)), class = "fake_int128")
    },
    from = function(x) arrow_array(unclass(x)),
    class = "fake_int128"
  )
  local_registration("d:*", to = function(array, schema) {
    rep("decimal", arrow_info_length(array))
  })
  proto <- structure(character(), class = "fake_int128")
  column <- test_fixed("d:38,0", c(1, 2), 16L)
  expect_identical(arrow_to_r(column), c("decimal", "decimal"))
  out <- arrow_to_r(column, to = proto)
  expect_s3_class(out, "fake_int128")
  expect_identical(unclass(out), c("int128", "int128"))

  schema <- test_schema(zspec(
    "+s",
    children = list(zspec("d:38,0", "h"), zspec("d:38,0", "d"))
  ))
  batch <- test_array(
    schema,
    1,
    list(NULL),
    children = list(
      test_array_spec(1, list(NULL, le_int(1, 16L))),
      test_array_spec(1, list(NULL, le_int(1, 16L)))
    )
  )
  df <- arrow_to_r(batch, to = list(h = proto))
  expect_s3_class(df$h, "fake_int128")
  expect_identical(df$d, "decimal")

  other <- structure(character(), class = "not_registered")
  expect_error(arrow_to_r(column, to = other), class = "zuarrow_type_error")
})

test_that("an inexact registration named in `to` needs warn or allow", {
  local_registration(
    "fake.approx",
    to = function(array, schema) rep(0, arrow_info_length(array)),
    from = function(x) arrow_array(unclass(x)),
    class = "fake_approx",
    exact = FALSE
  )
  proto <- structure(double(), class = "fake_approx")
  column <- test_fixed("d:38,0", 1, 16L)
  expect_error(arrow_to_r(column, to = proto), class = "zuarrow_type_error")
  expect_identical(arrow_to_r(column, to = proto, lossy = "allow"), 0)
  expect_warning(
    arrow_to_r(column, to = proto, lossy = "warn"),
    class = "zuarrow_lossy_warning"
  )
})

test_that("a from handler whose type depends on the values writes in batches", {
  # int8 when every value fits, int16 otherwise: the type is the whole
  # column's, and each batch is a slice of one array (issue #91).
  local_registration(
    "s",
    from = function(x) {
      v <- unclass(x)
      arrow_array(v, schema = if (all(abs(v) < 128L)) "c" else "s")
    },
    class = "fake_wide"
  )
  x <- structure(c(1L, 2L, 300L, 4L, 5L), class = "fake_wide")
  df <- data.frame(id = 1:5)
  df$w <- x

  stream <- arrow_stream(df, batch = 2)
  expect_identical(format(arrow_schema(stream)), "struct<id: int32, w: int16>")
  expect_identical(as.data.frame(stream)$w, unclass(x))

  bytes <- arrow_write(df, NULL, format = "stream", batch = 2)
  expect_identical(arrow_read(bytes)$w, unclass(x))

  small <- structure(1:3, class = "fake_wide")
  expect_identical(format(arrow_schema(arrow_array(small))), "int8")
})

test_that("a batch keeps the whole registered column's array alive", {
  local_registration(
    "i",
    from = function(x) arrow_array(unclass(x)),
    class = "fake_int"
  )
  df <- data.frame(id = 1:4)
  df$v <- structure(c(10L, 20L, 30L, 40L), class = "fake_int")
  stream <- arrow_stream(df, batch = 3)
  rm(df)
  gc()
  expect_identical(as.data.frame(stream)$v, c(10L, 20L, 30L, 40L))
})

test_that("copied slices keep nulls and bits across batch boundaries", {
  local_registration(
    "i",
    from = function(x) arrow_array(unclass(x)),
    class = "fake_int"
  )
  local_registration(
    "b",
    from = function(x) arrow_array(unclass(x)),
    class = "fake_bool"
  )
  v <- c(1L, NA, 3L, 4L, NA, 6L, 7L, 8L, 9L, NA, 11L)
  b <- c(TRUE, NA, FALSE, TRUE, TRUE, NA, FALSE, FALSE, TRUE, TRUE, NA)
  df <- data.frame(id = seq_along(v))
  df$v <- structure(v, class = "fake_int")
  df$b <- structure(b, class = "fake_bool")
  for (batch in c(1, 3, 5, 10)) {
    bytes <- arrow_write(df, NULL, format = "stream", batch = batch)
    out <- arrow_read(bytes)
    expect_identical(out$v, v, info = batch)
    expect_identical(out$b, b, info = batch)
  }
})

test_that("a variable-width registered column is built per batch", {
  local_registration(
    "u",
    from = function(x) arrow_array(unclass(x)),
    class = "fake_text"
  )
  df <- data.frame(id = 1:5)
  df$t <- structure(c("a", "bb", NA, "dddd", "e"), class = "fake_text")
  bytes <- arrow_write(df, NULL, format = "stream", batch = 2)
  expect_identical(arrow_read(bytes)$t, unclass(df$t))
})

test_that("a package registering its own key again is silent", {
  local_unload_hooks("utils")
  local_registration("l", to = as_text_int64, package = "utils")
  expect_no_message(
    arrow_register("l", to = as_text_int64, package = "utils")
  )
})

test_that("a dictionary column is handled by its value type, decoded", {
  seen <- local_decimal_text()
  spec <- zspec("i", "x")
  spec$dictionary <- zspec("d:5,1")
  array <- test_array(
    test_schema(spec),
    5,
    list(as.raw(0x1b), le_int(c(0, 1, 0, 2, 0), 4L)),
    null_count = 1,
    dictionary = test_array_spec(
      3,
      list(as.raw(0x03), le_int(c(15, -25, 0), 16L)),
      null_count = 1
    )
  )
  expect_identical(arrow_to_r(array), c("1.5", "-2.5", NA, NA, "1.5"))
  expect_identical(seen$formats, "decimal128(5, 1)")
})

test_that("a run-end encoded column is handled by its value type, decoded", {
  seen <- local_decimal_text()
  schema <- test_schema(zspec(
    "+r",
    children = list(zspec("i", "run_ends", flags = 0L), zspec("d:5,1"))
  ))
  array <- test_array(
    schema,
    4,
    list(),
    offset = 1,
    children = list(
      test_array_spec(3, list(NULL, le_int(c(2, 3, 5), 4L))),
      test_array_spec(
        3,
        list(as.raw(0x05), le_int(c(15, 0, -25), 16L)),
        null_count = 1
      )
    )
  )
  df <- as.data.frame(test_stream(
    test_schema(zspec(
      "+s",
      children = list(zspec(
        "+r",
        "x",
        children = list(zspec("i", "run_ends", flags = 0L), zspec("d:5,1"))
      ))
    )),
    list(test_array(
      test_schema(zspec(
        "+s",
        children = list(zspec(
          "+r",
          "x",
          children = list(zspec("i", "run_ends", flags = 0L), zspec("d:5,1"))
        ))
      )),
      2,
      list(NULL),
      children = list(test_array_spec(
        2,
        list(),
        children = list(
          test_array_spec(1, list(NULL, le_int(2, 4L))),
          test_array_spec(1, list(NULL, le_int(7, 16L)))
        )
      ))
    ))
  ))
  expect_identical(arrow_to_r(array), c("1.5", NA, "-2.5", "-2.5"))
  expect_identical(df$x, c("0.7", "0.7"))
  expect_identical(unique(seen$formats), "decimal128(5, 1)")
})

test_that("a handler for the index type never gets a dictionary", {
  local_registration("l", to = function(array, schema) stop("not this one"))
  spec <- zspec("l", "x")
  spec$dictionary <- zspec("u")
  array <- test_array(
    test_schema(spec),
    3,
    list(NULL, le_int(c(0, 1, 0), 8L)),
    dictionary = test_array_spec(
      2,
      list(NULL, le_int(c(0, 1, 2), 4L), charToRaw("ab"))
    )
  )
  expect_identical(arrow_to_r(array), factor(c("a", "b", "a")))
})

test_that("encoded values the decoder can't copy are a type error", {
  local_registration("+w:*", to = function(array, schema) "x", exact = TRUE)
  spec <- zspec("i", "x")
  spec$dictionary <- zspec("+w:1", children = list(zspec("i", "item")))
  array <- test_array(
    test_schema(spec),
    1,
    list(NULL, le_int(0, 4L)),
    dictionary = test_array_spec(
      1,
      list(NULL),
      children = list(test_array_spec(1, list(NULL, le_int(1, 4L))))
    )
  )
  expect_error(arrow_to_r(array), class = "zuarrow_type_error")
})

test_that("registration arguments are checked", {
  expect_error(
    arrow_register("zar_test_key", from = 1, class = "zar_test_class"),
    class = "zuarrow_registry_error"
  )
  expect_error(
    arrow_register(
      "zar_test_key",
      to = function(array, schema) NULL,
      package = "zuarrowNoSuchPackage"
    ),
    class = "zuarrow_dependency_error"
  )
  expect_error(
    arrow_register(
      "zar_test_key",
      to = function(array, schema) NULL,
      package = 1
    ),
    class = "zuarrow_registry_error"
  )
  expect_error(arrow_unregister(1), class = "zuarrow_registry_error")
  expect_false("zar_test_key" %in% arrow_registry()$key)
})

test_that("a `from` handler that returns no array is a registry error", {
  local_registration(
    "zar_test_not_array",
    from = function(x) unclass(x),
    class = "zar_test_not_array"
  )
  x <- structure(1:3, class = "zar_test_not_array")
  expect_error(arrow_array(x), class = "zuarrow_registry_error")
})

test_that("a handler whose nested type differs per batch is refused", {
  # list<int32> when every value fits, list<int64> otherwise: the top-level
  # format is "+l" either way, so only the child tells them apart (#100).
  local_registration(
    "+l",
    from = function(x) {
      v <- unclass(x)
      item <- if (all(abs(v) < 2^31)) "i" else "l"
      spec <- zspec("+l", children = list(zspec(item, "item")))
      arrow_array(as.list(v), schema = test_schema(spec))
    },
    class = "fake_nested"
  )
  df <- data.frame(id = 1:4)
  df$x <- structure(c(1, 2, 3e12, 4), class = "fake_nested")
  expect_error(
    arrow_to_r(arrow_stream(df, batch = 2), lossy = "allow"),
    class = "zuarrow_registry_error"
  )
  expect_error(
    arrow_write(df, NULL, format = "stream", batch = 2),
    class = "zuarrow_registry_error"
  )
})

test_that("a string dictionary's handler gets its decoded values", {
  seen <- new.env()
  local_registration("u", to = function(array, schema) {
    seen$format <- format_of(schema)
    seen$length <- arrow_info_length(array)
    structure(arrow_to_r(array), class = "fake_text")
  })
  spec <- zspec("i", "x")
  spec$dictionary <- zspec("u")
  # The dictionary is sliced: its first value, "x", is not part of it.
  array <- test_array(
    test_schema(spec),
    5,
    list(as.raw(0x17), le_int(c(2, 0, 1, 0, 2), 4L)),
    null_count = 1,
    dictionary = test_array_spec(
      3,
      list(as.raw(0x0b), le_int(c(0, 1, 3, 3, 6), 4L), charToRaw("xabcde")),
      null_count = 1,
      offset = 1
    )
  )
  expect_identical(
    arrow_to_r(array),
    structure(c("cde", "ab", NA, NA, "cde"), class = "fake_text")
  )
  expect_identical(seen$format, "u")
  expect_equal(seen$length, 5)
})

test_that("a boolean dictionary's handler gets its decoded bits", {
  local_registration("b", to = function(array, schema) {
    structure(arrow_to_r(array), class = "fake_bool")
  })
  spec <- zspec("c", "x")
  spec$dictionary <- zspec("b")
  # From bit 3 the dictionary is TRUE, NA, TRUE, TRUE, FALSE. The NA's data
  # bit is set, so only its validity bit makes it null.
  array <- test_array(
    test_schema(spec),
    6,
    list(NULL, as.raw(c(9, 0, 1, 2, 3, 4, 0))),
    offset = 1,
    dictionary = test_array_spec(
      5,
      list(as.raw(0xef), as.raw(0x78)),
      null_count = 1,
      offset = 3
    )
  )
  expect_identical(
    arrow_to_r(array),
    structure(c(TRUE, NA, TRUE, TRUE, FALSE, TRUE), class = "fake_bool")
  )
})

test_that("a handler for the dictionary values' extension gets them", {
  seen <- new.env()
  local_registration("zuarrow.test_text", to = function(array, schema) {
    seen$spec <- .Call(zuarrow:::zar_c_schema_to_spec, schema)
    structure(as.vector(arrow_to_r(array)), class = "fake_text")
  })
  spec <- zspec("i", "x")
  spec$dictionary <- zspec("u")
  spec$dictionary$metadata <- list(
    "ARROW:extension:name" = charToRaw("zuarrow.test_text"),
    "ARROW:extension:metadata" = raw()
  )
  array <- test_array(
    test_schema(spec),
    3,
    list(NULL, le_int(c(1, 0, 1), 4L)),
    dictionary = test_array_spec(
      2,
      list(NULL, le_int(c(0, 1, 3), 4L), charToRaw("abc"))
    )
  )
  expect_identical(
    arrow_to_r(array),
    structure(c("bc", "a", "bc"), class = "fake_text")
  )
  expect_identical(seen$spec$format, "u")
  expect_identical(
    rawToChar(seen$spec$metadata[["ARROW:extension:name"]]),
    "zuarrow.test_text"
  )
})

test_that("a dictionary index outside its dictionary is a format error", {
  local_registration("u", to = function(array, schema) arrow_to_r(array))
  spec <- zspec("i", "x")
  spec$dictionary <- zspec("u")
  array <- test_array(
    test_schema(spec),
    2,
    list(NULL, le_int(c(0, 2), 4L)),
    dictionary = test_array_spec(
      2,
      list(NULL, le_int(c(0, 1, 2), 4L), charToRaw("ab"))
    )
  )
  expect_error(arrow_to_r(array), class = "zuarrow_format_error")
})

test_that("a run-end encoding shorter than its array is a format error", {
  local_decimal_text()
  schema <- test_schema(zspec(
    "+r",
    children = list(zspec("i", "run_ends", flags = 0L), zspec("d:5,1"))
  ))
  array <- test_array(
    schema,
    4,
    list(),
    children = list(
      test_array_spec(1, list(NULL, le_int(2, 4L))),
      test_array_spec(1, list(NULL, le_int(15, 16L)))
    )
  )
  expect_error(arrow_to_r(array), class = "zuarrow_format_error")
})
