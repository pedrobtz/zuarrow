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

  `NULL`, or a function of `(array, schema)` or `(array, schema, lossy)`
  returning an R vector.

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

- an extension name, such as `"r.decimal"`.

When several keys match a column, the extension name wins, then the
exact format string, then the pattern registered first. So a
`decimal128(38, 0)` column is read by a `"d:*"` registration, even where
it holds integers; naming a prototype of another registered class in the
`to` of
[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
is how a caller opts into that class's handler instead. A package that
registers a pattern again, as on a reload, keeps its place among the
patterns; `arrow_unregister()` forgets it.

`to` converts Arrow to R: a function of `(array, schema)`, the column's
array and schema handles, returning an R vector of the array's length.
It may be implemented in C against nanoarrow's `r.h` layout. It is
called once per batch, and the pieces are combined with
[`c()`](https://rdrr.io/r/base/c.html). A function of
`(array, schema, lossy)` also receives the caller's `lossy` policy, so a
handler can apply it to values its class cannot hold, such as one equal
to its `NA` sentinel: an error under `"error"`, `NA` with a warning
under `"warn"`. A `to` that cannot be called with two or three arguments
is a `zuarrow_registry_error`.

`from` converts R to Arrow: a function of `(x)` returning an array
handle of `x`'s length, used for every object that inherits from
`class`. It receives the whole column, and the column's type is that
array's, in
[`arrow_schema()`](https://pedrobtz.github.io/zuarrow/reference/arrow_schema.md)
too. An array of another length is a `zuarrow_registry_error`. Where
several registrations' classes match an object, the one whose class
comes first in `class(x)` is used, for `from` and for a prototype in the
`to` of
[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md).

Inside `to`,
[`arrow_to_r()`](https://pedrobtz.github.io/zuarrow/reference/arrow_to_r.md)
on the same column uses the built-in conversion, so a handler can start
from it.

A registration declares whether it is exact. One that is not is used
only under `lossy = "warn"` or `"allow"`, and may not replace a type
whose built-in conversion is exact. An extension is exact when its
storage type is: an inexact registration for `arrow.bool8`, `arrow.json`
or `arrow.uuid` is refused, and one that would read a column of exact
storage is a `zuarrow_registry_error`. Registering a key again replaces
the earlier registration, with a message naming both packages when
another package owned it.

A dictionary or run-end encoded column is matched by its value type, not
its index or run-end type, and `to` receives an array of its decoded
values, one per row. Values of a fixed width, binary or string decode;
any other layout is a `zuarrow_type_error`.

A union has no R form, but an extension over a `dense_union` or a
`sparse_union`, such as `geoarrow.geometry`, can be registered. Its `to`
receives the union array as nanoarrow lays it out: the type ids, a dense
union's offsets and every child, whole. A sliced union keeps its offset,
and the children are not sliced, as the Arrow format lays it out. Its
null count is 0, since a union has no validity bitmap. With no handler
for its extension name, a union column is a `zuarrow_lossy_error`.

Registered handlers apply to the top-level columns of a data frame and
to the fields of nested data frames, at any depth, not to the items of a
list column. A field under a null row of its data frame is `NA`.

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
