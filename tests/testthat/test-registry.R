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

test_that("a handler sees a sliced field", {
  skip_if_not_installed("nanoarrow")
  local_registration("i", to = function(array, schema) arrow_to_r(array) * 10L)
  array <- nanoarrow::as_nanoarrow_array(data.frame(a = 1:4))
  sliced <- nanoarrow::nanoarrow_array_modify(
    array,
    list(offset = 1, length = 2)
  )
  expect_identical(arrow_to_r(sliced)$a, c(20L, 30L))
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
  exact <- c("tss:", "tsm:UTC", "+w:4", "+vl", "+vL", "tss:*", "tsm*", "+v*")
  for (key in exact) {
    expect_error(
      arrow_register(key, to = function(a, s) 1, exact = FALSE),
      class = "zuarrow_registry_error",
      info = key
    )
  }
  # Lossy defaults may still take an inexact registration.
  for (key in c("tsn:UTC", "tsu:*", "tdm")) {
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
