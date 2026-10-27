# Oracle 3 (design section 9) over every built-in type: the same values,
# built by nanoarrow and by zuarrow, compare equal, and each package's
# conversion reads both handles the same way. The cases live in
# helper-interop.R.

test_that("the cases cover every built-in type", {
  skip_if_not_installed("nanoarrow")
  types <- unlist(strsplit(arrow_types()$arrow, ", ", fixed = TRUE))
  covered <- vapply(interop_cases(), `[[`, "", "arrow")
  expect_setequal(unique(covered), types)
})

test_that("nanoarrow and zuarrow build and read every type alike", {
  skip_if_not_installed("nanoarrow")
  withr::local_options(nanoarrow.warn_unregistered_extension = FALSE)
  # nanoarrow's own reading of a handle, or the class of its error.
  na_read <- function(x, df = FALSE) {
    tryCatch(
      suppressWarnings(
        if (df) as.data.frame(x) else nanoarrow::convert_array(x)
      ),
      error = function(e) "unsupported"
    )
  }
  for (case in interop_cases()) {
    na <- case$nanoarrow()
    format <- format(arrow_schema(na))
    expect_true(arrow_validate(na, "full"), info = format)
    if (!case$r_form) {
      zu <- case$zuarrow()
      expect_error(arrow_to_r(na), class = "zuarrow_lossy_error", info = format)
      expect_error(arrow_to_r(zu), class = "zuarrow_lossy_error", info = format)
    } else {
      r <- arrow_to_r(na, lossy = "character")
      zu <- if (is.null(case$zuarrow)) {
        arrow_array(r, schema = arrow_schema(na))
      } else {
        case$zuarrow()
      }
      expect_identical(arrow_to_r(zu, lossy = "character"), r, info = format)
    }
    expect_true(arrow_equal(zu, na), info = format)
    expect_true(arrow_equal(na, zu), info = format)
    expect_identical(na_read(zu), na_read(na), info = format)

    # The same column inside a data frame, converted by as.data.frame() on
    # both sides: zuarrow's method on zuarrow's handle, nanoarrow's on
    # nanoarrow's.
    if (case$r_form && is.null(case$zuarrow)) {
      na_df <- nanoarrow::nanoarrow_array_modify(
        nanoarrow::nanoarrow_array_init(nanoarrow::na_struct(list(
          x = nanoarrow::infer_nanoarrow_schema(na)
        ))),
        list(length = na$length, children = list(x = na))
      )
      df <- data.frame(row = seq_len(na$length))[, FALSE, drop = FALSE]
      df$x <- r
      zu_df <- arrow_array(df, schema = arrow_schema(na_df))
      expect_true(arrow_equal(zu_df, na_df), info = format)
      expect_identical(
        as.data.frame(zu_df, lossy = "character"),
        arrow_to_r(na_df, lossy = "character"),
        info = format
      )
      expect_identical(
        na_read(zu_df, df = FALSE),
        na_read(na_df, df = TRUE),
        info = format
      )
    }
  }
})
