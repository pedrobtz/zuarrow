# a level with an embedded NUL is cut there under warn and allow

    Code
      arrow_to_r(array)
    Condition
      Error in `arrow_to_r()`:
      ! Column 1 (Arrow format `i`) can't be converted to R exactly: a nested string value holds a string with an embedded NUL. Use `lossy = "allow"` to accept the loss.

