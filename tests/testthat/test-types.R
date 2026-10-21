test_that("arrow_types() lists the built-in table", {
  types <- arrow_types()
  expect_s3_class(types, "data.frame")
  expect_named(
    types,
    c("arrow", "format", "r", "exact", "lossy_r", "exact_with")
  )
  expect_true(all(
    c("int64", "uint32", "date32", "interval") %in%
      unlist(strsplit(types$arrow, ", "))
  ))
  expect_identical(types$exact_with[types$arrow == "int64"], "zuint")
})
