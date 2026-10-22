test_that("copy = FALSE gives the same values as copying", {
  df <- data.frame(
    i = 1:6,
    s = c("a", NA, "café", "", "zz", NA),
    stringsAsFactors = FALSE
  )
  copied <- arrow_to_r(arrow_stream(df, batch = 4L))
  deferred <- arrow_to_r(arrow_stream(df, batch = 4L), copy = FALSE)
  expect_false(is.null(deferred_info(deferred$s)))
  expect_identical(deferred, copied)
  expect_identical(deferred$s, df$s)
})

test_that("strings are created on first use and the batches then let go", {
  x <- arrow_to_r(arrow_array(c("x", "y", "z")), copy = FALSE)
  expect_identical(deferred_info(x), list(made = 0, holds_arrays = TRUE))
  expect_identical(x[[2]], "y")
  expect_identical(deferred_info(x)$made, 1)
  expect_identical(x[[2]], "y")
  expect_identical(deferred_info(x)$made, 1)
  expect_identical(nchar(x), c(1L, 1L, 1L))
  expect_identical(deferred_info(x), list(made = 3, holds_arrays = FALSE))
})

test_that("large_string and sliced arrays are deferred", {
  big <- arrow_array(c("p", NA, "qr"), schema = "U")
  x <- arrow_to_r(big, copy = FALSE)
  expect_false(is.null(deferred_info(x)))
  expect_identical(x, c("p", NA, "qr"))

  skip_if_not_installed("nanoarrow")
  sliced <- nanoarrow::nanoarrow_array_modify(
    nanoarrow::as_nanoarrow_array(c("a", NA, "c", "d")),
    list(offset = 1L, length = 2L)
  )
  y <- arrow_to_r(sliced, copy = FALSE)
  expect_false(is.null(deferred_info(y)))
  expect_identical(y, c(NA, "c"))
})

test_that("a struct field is deferred unless the struct has nulls", {
  df <- data.frame(id = 1:2)
  df$inner <- data.frame(s = c("a", "b"))
  out <- arrow_to_r(arrow_array(df), copy = FALSE)
  expect_false(is.null(deferred_info(out$inner$s)))
  expect_identical(out, arrow_to_r(arrow_array(df)))

  # A struct with a null row: its fields are copied, so the row is NA
  schema <- arrow_schema(data.frame(s = I(data.frame(x = "a"))))
  inner <- test_array_spec(
    2,
    list(as.raw(0x02), NULL),
    null_count = 1,
    children = list(test_array_spec(
      2,
      list(NULL, le_int(c(0, 1, 2), 4L), charToRaw("pq"))
    ))
  )
  array <- test_array(schema, 2, list(NULL), children = list(inner))
  nulls <- arrow_to_r(array, copy = FALSE)
  expect_null(deferred_info(nulls$s$x))
  expect_identical(nulls, arrow_to_r(array))
  expect_identical(nulls$s$x, c(NA, "q"))
})

test_that("factors, dictionaries and other types are copied", {
  df <- data.frame(f = factor(c("a", "b", "a")), d = c(1.5, 2, 3))
  out <- arrow_to_r(arrow_array(df), copy = FALSE)
  expect_null(deferred_info(out$f))
  expect_null(deferred_info(levels(out$f)))
  expect_null(deferred_info(out$d))
  expect_identical(out, df)
})

test_that("copy = FALSE raises the same errors at the same time", {
  bad <- test_array(
    "u",
    1,
    list(NULL, le_int(c(0, 2), 4L), as.raw(c(0xc3, 0x28)))
  )
  expect_error(arrow_to_r(bad), class = "zuarrow_format_error")
  expect_error(arrow_to_r(bad, copy = FALSE), class = "zuarrow_format_error")

  nul <- test_array(
    "u",
    1,
    list(NULL, le_int(c(0, 3), 4L), as.raw(c(0x61, 0, 0x62)))
  )
  expect_error(arrow_to_r(nul), class = "zuarrow_lossy_error")
  expect_error(arrow_to_r(nul, copy = FALSE), class = "zuarrow_lossy_error")
  expect_identical(
    arrow_to_r(nul, lossy = "allow", copy = FALSE),
    arrow_to_r(nul, lossy = "allow")
  )
})

test_that("a released array is a handle error, not a crash", {
  skip_if_not_installed("nanoarrow")
  array <- arrow_array(c("x", "y"))
  x <- arrow_to_r(array, copy = FALSE)
  nanoarrow::nanoarrow_pointer_release(array)
  expect_error(x[[1]], class = "zuarrow_handle_error")
})

test_that("a deferred vector saves and modifies as an ordinary one", {
  x <- arrow_to_r(arrow_array(c("a", "b", NA)), copy = FALSE)
  path <- withr::local_tempfile(fileext = ".rds")
  saveRDS(x, path)
  y <- readRDS(path)
  expect_null(deferred_info(y))
  expect_identical(y, c("a", "b", NA))

  x[2] <- "q"
  expect_identical(x, c("a", "q", NA))
  expect_identical(sort(x), c("a", "q"))
  expect_identical(paste0(x, "!"), c("a!", "q!", "NA!"))
})

test_that("arrow_read() and arrow_next() take copy", {
  df <- data.frame(s = c("a", "b", "c"), stringsAsFactors = FALSE)
  bytes <- arrow_write(df, NULL)
  out <- arrow_read(bytes, copy = FALSE)
  expect_false(is.null(deferred_info(out$s)))
  expect_identical(out, arrow_read(bytes))

  stream <- arrow_read(bytes, lazy = TRUE)
  batch <- arrow_next(stream, copy = FALSE)
  expect_false(is.null(deferred_info(batch$s)))
  expect_identical(batch, df)
  expect_identical(
    as.data.frame(arrow_array(df), copy = FALSE),
    as.data.frame(arrow_array(df))
  )
})

test_that("copy must be TRUE or FALSE", {
  x <- arrow_array("a")
  expect_error(arrow_to_r(x, copy = NA), class = "zuarrow_type_error")
  expect_error(arrow_to_r(x, copy = "no"), class = "zuarrow_type_error")
  expect_error(
    arrow_read(arrow_write(data.frame(a = 1), NULL), copy = 1),
    class = "zuarrow_type_error"
  )
})

test_that("deferred strings survive garbage collection", {
  withr::local_seed(1)
  values <- replicate(200, paste(sample(letters, 5), collapse = ""))
  x <- arrow_to_r(
    arrow_stream(data.frame(s = values), batch = 37L),
    copy = FALSE
  )$s
  gc()
  expect_identical(x[c(1, 100, 200)], values[c(1, 100, 200)])
  gc()
  expect_identical(x, values)
})

test_that("strings checked as one byte range still fail element by element", {
  # "é" split across two elements: the bytes are valid UTF-8 as a whole,
  # but neither element is
  split <- test_array(
    "u",
    2,
    list(NULL, le_int(c(0, 1, 2), 4L), as.raw(c(0xc3, 0xa9)))
  )
  expect_error(arrow_to_r(split), class = "zuarrow_format_error")
  expect_error(arrow_to_r(split, copy = FALSE), class = "zuarrow_format_error")

  # A null slot's bytes are undefined, so invalid ones there are not an error
  garbage <- test_array(
    "u",
    2,
    list(as.raw(0x01), le_int(c(0, 1, 2), 4L), as.raw(c(0x61, 0xff))),
    null_count = 1
  )
  expect_identical(arrow_to_r(garbage), c("a", NA))
  expect_identical(arrow_to_r(garbage, copy = FALSE), c("a", NA))
})
