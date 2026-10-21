test_that("a run-end encoded array decodes to its values", {
  schema <- test_schema(zspec(
    "+r",
    children = list(zspec("i", "run_ends", flags = 0L), zspec("u", "values"))
  ))
  array <- test_array(
    schema,
    5,
    list(),
    children = list(
      test_array_spec(3, list(NULL, le_int(c(2, 3, 5), 4L))),
      test_array_spec(
        3,
        list(as.raw(0x05), le_int(c(0, 1, 1, 2), 4L), charToRaw("ab")),
        null_count = 1
      )
    )
  )
  expect_identical(arrow_to_r(array), c("a", "a", NA, "b", "b"))
})

test_that("a sliced run-end encoded array decodes from its offset", {
  schema <- test_schema(zspec(
    "+r",
    children = list(zspec("s", "run_ends", flags = 0L), zspec("i", "values"))
  ))
  array <- test_array(
    schema,
    3,
    list(),
    offset = 1,
    children = list(
      test_array_spec(2, list(NULL, le_int(c(2, 4), 2L))),
      test_array_spec(2, list(NULL, le_int(c(10, 20), 4L)))
    )
  )
  expect_identical(arrow_to_r(array), c(10L, 20L, 20L))
})
