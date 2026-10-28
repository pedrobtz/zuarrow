# a later registration replaces the earlier one with a message

    Code
      arrow_register("l", to = as_text_int64, package = "stats")
    Message
      zuarrow: the registration of `l` by package stats replaces the one by package utils.

# conditions from a handled nested field name its path

    Code
      arrow_to_r(array)
    Condition
      Error in `arrow_to_r()`:
      ! Column `s$b` (Arrow format `l`) can't be converted to R exactly: row 1 holds 9007199254740994. Load zuint to read it exactly, or use `lossy = "character"` for its exact text, or `lossy = "allow"` to accept the loss.

