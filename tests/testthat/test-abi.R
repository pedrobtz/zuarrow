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

test_that("the archive and its headers are installed", {
  skip_on_cran()
  expect_true(file.exists(abi_archive_path()))
  include <- system.file("include", package = "zuarrow")
  if (!file.exists(file.path(include, "zuarrow", "nanoarrow.h"))) {
    abi_unavailable("zuarrow is not installed with its headers")
  }
  for (f in c("zuarrow.h", "zukomp.h", file.path("zuarrow", "nanoarrow.h"))) {
    expect_true(file.exists(file.path(include, f)), info = f)
  }
  # The copies are the files the archive was built from.
  vendored <- test_path("..", "..", "src", "vendor", "nanoarrow", "nanoarrow.h")
  if (file.exists(vendored)) {
    expect_identical(
      unname(tools::md5sum(file.path(include, "zuarrow", "nanoarrow.h"))),
      unname(tools::md5sum(vendored))
    )
  }
  licenses <- system.file("licenses", package = "zuarrow")
  expect_true(all(file.exists(
    file.path(licenses, c("nanoarrow-LICENSE.txt", "nanoarrow-NOTICE.txt"))
  )))
})

test_that("the archive calls no R and nothing CRAN's check reports", {
  skip_on_cran()
  abi_skip_instrumented()
  undefined <- sub("^_+", "", abi_archive_undefined())
  # It does call the C library, so an empty listing is a broken tool.
  expect_true("malloc" %in% undefined)
  expect_identical(
    grep("^(Rf_|R_|Rprintf|REprintf)", undefined, value = TRUE),
    character()
  )
  expect_identical(intersect(undefined, abi_forbidden), character())
})

test_that("every symbol the archive defines is zuarrow's, zar_ or flatcc's", {
  skip_on_cran()
  abi_skip_instrumented()
  defined <- abi_archive_defined_globals()
  expect_true("zuarrow_open_stream" %in% defined)
  expect_true("zuarrowArrowArrayInitFromType" %in% defined)
  expect_true("zuarrowArrowBasicArrayStreamInit" %in% defined)
  # nanoarrow's names are namespaced to zuarrowArrow*; flatcc's runtime is
  # not, which design section 14.1 records.
  expect_identical(
    grep("^(zuarrow|zar_|flatcc_)", defined, value = TRUE, invert = TRUE),
    character()
  )
  expect_identical(grep("^Arrow", defined, value = TRUE), character())
})

test_that("the archive holds no mutable global", {
  skip_on_cran()
  abi_skip_instrumented()
  expect_identical(abi_archive_writable(), character())
})
