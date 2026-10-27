# a factor code outside its levels is a type error

    Code
      writeLines(messages)
    Output
      row 2 holds code 5, outside the factor's 1 levels
      row 2 holds code 0, outside the factor's 1 levels
      row 2 holds code -1, outside the factor's 1 levels

# invalid UTF-8 and bytes-encoded strings are type errors

    Code
      writeLines(messages)
    Output
      row 2 is not valid UTF-8
      row 2 is not valid UTF-8

