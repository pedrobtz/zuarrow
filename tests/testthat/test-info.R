test_that("zuarrow_info() reports the versions it is built from", {
  info <- zuarrow_info()
  expect_named(info, c("zuarrow", "nanoarrow", "ipc_metadata"))
  expect_identical(info$nanoarrow, "0.9.0")
  expect_identical(info$ipc_metadata, "V5")
  expect_identical(info$zuarrow, as.character(utils::packageVersion("zuarrow")))
})
