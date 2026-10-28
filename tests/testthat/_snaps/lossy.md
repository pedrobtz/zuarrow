# the lossy error names the column, type, row and target

    Code
      arrow_to_r(array)
    Condition
      Error in `arrow_to_r()`:
      ! Column `x` (Arrow format `l`) can't be converted to R exactly: row 2 holds 9007199254740994. Load zuint to read it exactly, or use `lossy = "character"` for its exact text, or `lossy = "allow"` to accept the loss.

# an embedded NUL is lossy with no text form

    Code
      arrow_to_r(nul)
    Condition
      Error in `arrow_to_r()`:
      ! Column 1 (Arrow format `u`) can't be converted to R exactly: row 1 holds a string with an embedded NUL. Use `lossy = "allow"` to accept the loss.

---

    Code
      arrow_to_r(big)
    Condition
      Error in `arrow_to_r()`:
      ! Column 1 (Arrow format `l`) can't be converted to R exactly: row 1 holds 9007199254740994. Load zuint to read it exactly, or use `lossy = "character"` for its exact text, or `lossy = "allow"` to accept the loss.

