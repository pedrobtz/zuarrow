test_that("the shared object exports R_init_zuarrow only", {
  skip_on_cran()
  exports <- abi_exports()
  expect_identical(setdiff(exports, "R_init_zuarrow"), character())
  expect_true("R_init_zuarrow" %in% exports)
})

test_that("no exported symbol is a nanoarrow Arrow* name", {
  # NANOARROW_NAMESPACE renames nanoarrow's API to zuarrowArrow*, and hidden
  # visibility keeps even that out of the export table, so loading the
  # nanoarrow package in the same session cannot clash.
  skip_on_cran()
  expect_identical(grep("^Arrow", abi_exports(), value = TRUE), character())
})

test_that("no symbol CRAN's compiled-code check reports is referenced", {
  skip_on_cran()
  imports <- sub("^_+", "", abi_imports())
  expect_identical(intersect(imports, abi_forbidden), character())
})
