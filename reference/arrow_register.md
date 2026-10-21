# Register an exact R type for an Arrow type

A typed package, such as 'zuint', 'decimal' or 'zutempo', tells zuarrow
which R class is the exact form of an Arrow type. It does so in its
`.onLoad()`, when zuarrow is installed; the registration lasts for the
session and is removed when that package unloads.

## Usage

``` r
arrow_register(
  key,
  to = NULL,
  from = NULL,
  class = NULL,
  package = NULL,
  exact = TRUE
)

arrow_unregister(key)

arrow_registry()
```

## Arguments

- key:

  A format string, a prefix pattern or an extension name.

- to:

  `NULL`, or a function of `(array, schema)` returning an R vector.

- from:

  `NULL`, or a function of `(x)` returning an array handle.

- class:

  The R classes `from` handles.

- package:

  The registering package, so its registrations are removed when it
  unloads.

- exact:

  Whether the conversion is exact.

## Value

`arrow_register()` and `arrow_unregister()` return `key` invisibly.
`arrow_registry()` returns a data frame with columns `key`, `kind`,
`class`, `package` and `exact`.

## Details

The `key` is one of:

- an Arrow format string, matched exactly: `"l"` for `int64`;

- a prefix pattern ending in `*` for parameterised types: `"d:*"` for
  every decimal, `"tsn:*"` for every nanosecond timestamp;

- an extension name, such as `"r.decimal"`, which takes precedence over
  the storage type's key.

`to` converts Arrow to R: a function of `(array, schema)`, the column's
array and schema handles, returning an R vector of the array's length.
It may be implemented in C against nanoarrow's `r.h` layout. It is
called once per batch, and the pieces are combined with
[`c()`](https://rdrr.io/r/base/c.html).

`from` converts R to Arrow: a function of `(x)` returning an array
handle, used for every object that inherits from `class`.

Inside `to`,
[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
on the same column uses the built-in conversion, so a handler can start
from it.

A registration declares whether it is exact. One that is not is used
only under `lossy = "warn"` or `"allow"`, and may not replace a type
whose built-in conversion is exact. Registering a key again replaces the
earlier registration, with a message naming both packages.

Registered handlers apply to the top-level columns of a data frame and
to the fields of nested data frames, not to the items of a list column.

## Examples

``` r
arrow_register(
  "l",
  to = function(array, schema) arrow_to_r(array, to = character()),
  exact = TRUE
)
arrow_registry()
#>   key   kind class package exact
#> 1   l format          <NA>  TRUE
arrow_unregister("l")
```
