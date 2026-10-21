test_that("the shared object is loaded with the namespace", {
  expect_true("zuarrow" %in% names(getLoadedDLLs()))
})
