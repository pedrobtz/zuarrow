test_that("the shared object exports R_init_zuarrow only", {
  skip_on_cran()
  abi_skip_instrumented()
  exports <- abi_exports()
  expect_identical(setdiff(exports, "R_init_zuarrow"), character())
  expect_true("R_init_zuarrow" %in% exports)
})

test_that("no exported symbol is a nanoarrow Arrow* name", {
  # NANOARROW_NAMESPACE renames nanoarrow's API to zuarrowArrow*, and hidden
  # visibility keeps even that out of the export table, so loading the
  # nanoarrow package in the same session cannot clash.
  skip_on_cran()
  abi_skip_instrumented()
  expect_identical(grep("^Arrow", abi_exports(), value = TRUE), character())
})

test_that("no symbol CRAN's compiled-code check reports is referenced", {
  skip_on_cran()
  abi_skip_instrumented()
  imports <- sub("^_+", "", abi_imports())
  # The object calls R's API, so an empty or unparsed listing is a broken
  # tool or pattern, not a clean object.
  expect_true("Rf_allocVector" %in% imports)
  runtime <- sub("^_+", "", abi_runtime_imports())
  expect_identical(
    intersect(setdiff(imports, runtime), abi_forbidden),
    character()
  )
})

test_that("objdump import tables parse with and without an ordinal column", {
  out <- c(
    "The Import Tables (interpreted .idata section contents)",
    " vma:            Hint    Time      Forward  DLL       First",
    "                 Table   Stamp     Chain    Name      Thunk",
    " 0001c000       0001c0a0 00000000 00000000 0001c4e8 0001c1a0",
    "",
    "\tDLL Name: R.dll",
    "\tvma:  Hint/Ord Member-Name Bound-To",
    "\t1c5f0\t  123  Rf_allocVector",
    "",
    "\tDLL Name: api-ms-win-crt-stdio-l1-1-0.dll",
    "\tvma:     Ordinal  Hint  Member-Name  Bound-To",
    "\t1c6a8     <none>  0001  __acrt_iob_func\r",
    "\t1c6b0     <none>  0002  fwrite",
    ""
  )
  imports <- abi_objdump_imports(out)
  expect_true(all(
    c("Rf_allocVector", "__acrt_iob_func", "fwrite") %in% imports
  ))
  expect_false(any(grepl("Member-Name|<none>", imports)))
})
