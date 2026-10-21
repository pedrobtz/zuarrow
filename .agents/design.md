# RFC 0041: `zuarrow`, Arrow columns in R, exact or an error

Adopted from [RFC 0041](https://github.com/pedrobtz/packages/blob/main/rfcs/started/0041-zuarrow-arrow-columns-exact-or-error.md) on 2026-10-21. From here on this file is authoritative; the RFC is history.

- **Status:** Proposed. Merging this file adopts the design as the starting
  point for the package's own `.agents/design.md`; each decision in section
  13 stays the maintainer's until the package repository records it. Every
  decision here is **(C)**: the maintainer's note file for this RFC
  (`idea.txt`) was empty when the RFC was written, so the design starts
  from the family's existing Arrow commitments rather than from a
  conversation, and D1 (vendoring nanoarrow), D4 (`lossy = "error"` as
  the default) and D6 (handles that are nanoarrow's handles) are the ones
  most worth a second look. Revised the same day after the maintainer
  decided that `zukomp` ships lz4 and zstd in its core
  ([zukomp#55](https://github.com/pedrobtz/zukomp/issues/55)) and asked
  for the nanoarrow gaps of §1.3 to be closed in v0.1.0.
- **Date:** 2026-10-21.
- **Packages:** `zuarrow` (not yet created; the name was absent from
  crandb and from the `pedrobtz` account on 2026-10-21). `Imports:
  zukomp` and `LinkingTo: zukomp` for the IPC codecs (D2); nothing else.
  `Suggests: testthat, nanoarrow, arrow, zuint, decimal, zutempo`.
  Vendors the nanoarrow C library's core and IPC components
  (Apache-2.0), and its integration-testing header for the test harness
  only (§7). MIT for its own code, with the vendored licences in
  `inst/COPYRIGHTS` (D14).
- **Source:** the Arrow Columnar Format specification, the Arrow C Data
  Interface, the C Stream Interface and the IPC streaming and file format
  pages at arrow.apache.org, read 2026-10-21 (the current 1.x format
  version; Stage 0 pins the minor); `apache/arrow-nanoarrow` at tag
  `apache-arrow-nanoarrow-0.9.0` (2026-07-31; CRAN 0.9.0 published
  2026-08-04), its `r/NEWS.md`, `r/R/ipc.R`, `r/R/infer-ptype.R` and
  `r/inst/include/nanoarrow/r.h`, which is the contract for the handle
  layout D6 adopts; `arrow` 25.0.1 on CRAN (2026-08-23) for the heavy
  alternative; `apache/arrow-testing`'s `data/arrow-ipc-stream/integration`
  golden files and `data/arrow-ipc-file` fuzz cases as the conformance
  corpus (§9); this repository's RFC 0009 §9 (zuint's Arrow bridge), RFC
  0031 §7.3 (zuggml's Arrow batches), RFC 0032 §2 (zuflow's Arrow input),
  RFC 0035 §4.1 (zutempo's storage), RFC 0036 (zutable), RFC 0040 §6.2
  (zumime's `ARROW1` and `FEA1` signatures), and `decimal`'s `R/arrow.R`,
  which registers an `r.decimal` extension type through the `arrow`
  package; `qio` 0.1.1's `DESCRIPTION` and `src/` (it vendors lz4 and
  zstd and exposes no Arrow interface); nanoarrow's open issues #728,
  #622, #617, #824, #833, #513, #952, #822, #594 and #370 and its
  `convert_array()` documentation, read 2026-10-21, as the record of what
  its binding leaves open (§1.3); zukomp#55 and qio#17, which move the
  codecs into `zukomp`. Nothing has been built.

## 1. What zuarrow is

`zuarrow` moves columns between R and the Apache Arrow columnar format.
In memory that is the Arrow C Data Interface, three C structs that
DuckDB, Polars, ADBC drivers, the `arrow` package, `nanoarrow` and
Python's pyarrow all produce and consume. On disk it is the Arrow IPC
format in both of its framings: the stream (`application/vnd.apache.arrow.stream`)
and the file with its footer (`.arrow`, also called Feather version 2).
The package reads and writes both, converts every Arrow type to an R
vector and back, and keeps a registry that says which R type is the exact
form of which Arrow type.

The rule that governs every conversion: **a value crosses exactly or the
call errors.** An `int64` column whose values exceed 2⁵³ does not become
a double with a warning; a nanosecond timestamp does not become a
`POSIXct` with its nanoseconds dropped; a 128-bit decimal does not become
a double. Each errors, naming the column and the R type that would carry
it exactly, which in the family is `zuint`, `zutempo` or `decimal`. When
that package is loaded, it has registered itself and the same call
succeeds. The caller may lower the bar to `warn` or `allow`, but never by
default.

The one-line statement that governs every decision below:

> **The Arrow columnar format in memory and on disk, one family
> dependency, no system library, the same answer on every machine, and
> no silent loss.**

### 1.1 What zuarrow is not

- **Not a query engine.** No filter, project, join or aggregate over
  Arrow data. DuckDB and Polars do that; `zutable` (RFC 0036) and `zugrp`
  (RFC 0037) are the family's answer over R vectors. zuarrow moves data;
  it does not compute on it.
- **Not Parquet.** `qio` reads and writes Parquet with its own type
  mapping. §14 records the bridge: `qio` exporting an Arrow stream so the
  two packages share one mapping.
- **Not a dataset or table object model.** No R6 `Table`, no
  `ChunkedArray`, no `Dataset`. A stream is a handle; the materialised
  form is a `data.frame`.
- **Not transport.** Arrow Flight, ADBC and the Python PyCapsule protocol
  are producers of streams, reached through their own packages. zuarrow
  accepts what they hand over.
- **Not a replacement for `nanoarrow`.** Its handles are nanoarrow's
  handles (D6), so a session with both loaded passes objects between them
  without conversion. §1.3 says what zuarrow adds.
- **Not compute on the device interface.** CUDA and other non-CPU
  memory are out of scope entirely.

### 1.2 Where it sits among existing packages

Two packages give R the Arrow format today. `arrow` is the Apache
project's full binding: libarrow C++, a C++20 toolchain, cmake for a
source build, eleven `Imports`, and everything from compute to S3
filesystems. It is the right tool when all of that is wanted and the
wrong size when a package needs only to receive a stream. `nanoarrow` is
the Apache project's small binding: no `Imports`, Apache-2.0, a vendored
C library, conversion of arrays and streams to R vectors, and since 0.5
and 0.6 an IPC reader and writer. It is maintained by the Arrow project
and is what RFC 0009 and RFC 0031 assumed as the R-side glue.

Outside R, every modern data system speaks the C Data Interface:
DuckDB, Polars, DataFusion, pyarrow, pandas 2, Velox, ADBC. The format is
stable, its specification is a page of C, and the IPC framing is a
FlatBuffers message plus 8-byte-aligned body buffers. The gap is not the
format. The gap is what R does with the columns once they arrive.

### 1.3 Why not `nanoarrow` alone

A family package that re-vendored nanoarrow and exposed the same surface
would add nothing and split the ecosystem, which is the test §5.4 of
`base-layer-candidates.md` applied to tree-sitter. zuarrow passes it only
because of what nanoarrow 0.9.0 leaves open, checked against its source
and its issue tracker on 2026-10-21. Most of it is nanoarrow's own
backlog, so the issue numbers are given and §15 Q1 asks the question
again at each release.

1. **Exact types.** The documented defaults send `uint32`, `int64`,
   `uint64`, `float` and `double` to `double()`, and the `convert_array()`
   documentation says the double conversion "currently does not warn"
   for values that do not round-trip; `decimal`, `interval` and the union
   types have no target at all (#594 is a decimal defect on Windows);
   `timestamp` becomes `POSIXct` at whatever precision survives a double;
   the character conversion does not validate UTF-8. Default inference
   consults a registry for extension names only, so a package cannot
   make `int64` exact without the caller passing `to`. The family has
   three exact column types nanoarrow cannot know about (`zuint`,
   `decimal`, `zutempo`) and today three different bridges in flight for
   them: `decimal` registers an extension type through `arrow`'s R6
   classes, RFC 0009 plans `convert_array()` targets through nanoarrow,
   and RFC 0031 reads the stream struct by hand. One registry keyed on
   storage types as well as extension names, populated by the typed
   packages, replaces all three (D3).
2. **The file format, the writer and the codecs.** The binding reads and
   writes the stream only; reading the file format with its footer is
   #728, open, although the C library decodes footers. The IPC writer
   cannot write dictionaries (#622) or compress (the C encoder has the
   hooks; `write_nanoarrow()` has no argument). Run-end-encoded and
   string-view arrays are outside the IPC reader and writer (#833, #824)
   and cannot be converted to R vectors (#617). LZ4 and zstd depend on
   optional system libraries, which `nanoarrow_with_lz4()` and
   `nanoarrow_with_zstd()` exist to ask about, so a compressed stream
   opens on one machine and fails on another. zuarrow reads and writes
   both framings, decodes the three newer layouts, and takes its codecs
   from `zukomp` (D2), so the answer is the same everywhere.
3. **Validation, comparison and metadata from R.** The C library has a
   full validation level for untrusted buffers, an array comparison, a
   metadata reader and builder, decimal-to-string helpers and a schema
   printer; the binding exposes none of them (#370 asks for the type
   notation). zuarrow runs full validation on every IPC input and exposes
   `arrow_validate()`, `arrow_equal()` and `arrow_metadata()` (§6.11).
4. **A conversion the family can call from C.** nanoarrow's `LinkingTo`
   header `r.h` ships the three structs and the external-pointer
   accessors, not the library and not the conversion, which lives in R.
   The family's typed packages need to hand an `ArrowArray` to a C
   function and get an R vector with the right class back, and the
   reverse. In v0.1.0 that is an R-level registry whose handlers may be
   C functions in the registering package; the C table proper is §14.
5. **Conversion cost.** Dictionary columns become factors only when
   asked (#513); the ALTREP string conversion recreates every `CHARSXP`
   on access (#952) and makes stream-to-data-frame slow for strings
   (#822). zuarrow converts factors by default and copies once in C,
   which sidesteps both until the zero-copy path of §14 is designed.
6. **No silent loss as the default.** This is a policy, not a feature,
   and the one that justifies a separate package: nanoarrow's defaults
   are chosen for convenience across the whole R ecosystem and will stay
   so. The family's rule is that a bridge errors rather than rounds.

If nanoarrow closes #728, #622 and #617 upstream, bundles its codecs and
grows an exact-targets registry, zuarrow shrinks to the family registry
and the C table of §14, and this RFC says so now so the question is
asked at each nanoarrow release (§15 Q1).

## 2. Scope

**In v0.1.0:**

- **Handles** (§6.1): schema, array and stream external pointers in
  nanoarrow's layout, accepted from and handed to any producer.
- **The type table** (§6.2): every Arrow type in the 1.x format to an R
  form and back, with the exact ones built in and the rest routed through
  the registry or refused.
- **Exact or error** (§6.3): the `lossy` argument, what counts as loss,
  the exact character fallback, and the message that names the exact
  target.
- **Nested types** (§6.4): struct, list, large list, fixed-size list,
  map, list view, as nested data frames and list columns.
- **Dictionaries** (§6.5): to and from factors, with `ordered`.
- **Extension types** (§6.6): names and metadata preserved; registered
  handlers; `arrow.bool8` built in.
- **Reading IPC** (§6.7): file and stream, from a path, a raw vector or a
  connection, eagerly or batch by batch, with column selection, LZ4 and
  zstd bodies through `zukomp`, dictionary batches and deltas, run-end,
  string-view and list-view layouts, full validation, limits.
- **Writing IPC** (§6.8): file and stream, from a data frame, an array or
  a stream, with batch size, compression, dictionary encoding of factors,
  schema metadata, byte-identical output across platforms.
- **Nulls** (§6.9): the NA, NaN and sentinel rules, both directions.
- **The registry** (§6.10): `arrow_register()` and its dispatch keys.
- **Validation, comparison and metadata** (§6.11): `arrow_validate()`,
  `arrow_equal()`, `arrow_metadata()` and the schema printer.
- A README and one article, "Receiving a DuckDB result without rounding".

**Not in v0.1.0, and why:**

- **Zero-copy views.** Wrapping an Arrow buffer as an ALTREP vector
  without copying is the right end state and RFC 0009 already owns the
  ALTREP classes for 64-bit integers. v0.1.0 copies once, in C, so the
  first release has one memory model to get right (§14).
- **Memory-mapped files.** Needs the zero-copy path to be worth anything,
  and `zufs` (candidates §5.2) is where mapping belongs (§14).
- **A C table.** `zuarrow_api_v1` with the conversion kernels for `zuint`,
  `zutempo` and `qio` to call from C. The registry's R-level shape should
  settle first; RFC 0031 §7.3 needs only the handle layout, which v0.1.0
  provides (§14).
- **Writing run-end-encoded, union and view types.** They are read
  (§6.7); writing them has no R source type.
- **Parquet, Flight, ADBC, the device interface, Python** (§1.1).

## 3. Position in the `zu*` family

| | zuarrow |
| --- | --- |
| Role | format; provider of a C table after v0.1.0 (§14) |
| R prefix | `arrow_` (D12) |
| Info function | `zuarrow_info()`: vendored versions, format version |
| Root condition class | `zuarrow_error` |
| Public C prefix | `zuarrow_` after v0.1.0; internal `zar_` / `ZAR_` |
| From C | not in v0.1.0 (§14) |
| Hides symbols | yes, from Stage 0 (R3) |
| Vendored code | nanoarrow core and ipc; testing header in tests (§7) |
| `Depends: R` | 4.1 (R2) |
| Language | en-GB (R2) |

The `zar_` prefix was checked on 2026-10-21 against the prefixes the
family's RFCs record (`zu_`, `zuf_`, `zb_`, `zuc_`, `zux_`, `zuh_`,
`znp_`, `ztp_`); Stage 0 verifies it against the installed packages.

**Relationships, as decided rather than as hoped:**

- **`nanoarrow`**: `Suggests`. Never `Imports` or `LinkingTo`: zuarrow
  vendors the C library (D1) and reproduces the handle layout (D6). Used
  in tests to prove interchange both ways, and as the target of delayed
  S3 registrations (`as_nanoarrow_array_stream()` and friends) so a
  zuarrow handle is accepted wherever a nanoarrow one is.
- **`arrow`**: `Suggests`. The heavy oracle (§9): it reads what zuarrow
  writes and zuarrow reads what it writes, including compressed bodies.
- **`zuint`** (RFC 0009): registers `int64`, `uint64`, `int128` (as
  `decimal128(p, 0)`) and `uint128` targets at load. Its own RFC's §9.1
  nanoarrow glue becomes a registration with zuarrow; its ALTREP wrapping
  is the zero-copy path of §14. Until zuint ships, those types error
  under the default policy with a message naming it.
- **`decimal`**: registers `decimal128` and `decimal256` and its
  `r.decimal` extension name, giving it a libarrow-free path beside the
  `arrow` one it has.
- **`zutempo`** (RFC 0035): registers `timestamp` at every unit and zone,
  `time64`, `duration` and `date64`; its `Instant` stores nanoseconds
  exactly (RFC 0035 §4.1), which is what makes `tsn:` exact.
- **`zuggml`** (RFC 0031 §7.3) and **`zuflow`** (RFC 0032): consumers.
  Their iterator takes a stream handle; with D6 it takes a zuarrow one
  unchanged, and zuggml can drop its plan to read the external pointer
  by hand in favour of the documented layout.
- **`zutable`** (RFC 0036): a consumer in a later version. An Arrow
  schema is a locked schema; `zutable` from a stream is the natural
  constructor and belongs to zutable's repository.
- **`zukomp`**: `Imports` and `LinkingTo`, the only dependency. Its
  core ships `zstd` and `lz4-frame` from the release that
  [zukomp#55](https://github.com/pedrobtz/zukomp/issues/55) tracks, and
  zuarrow drives them through `zukomp_get_api()` as the IPC decoder's and
  encoder's compression hooks (D2). Release order follows R10: that
  zukomp release reaches CRAN before zuarrow does, and the `LinkingTo`
  floor is its version. `qio` moves onto the same copy
  ([qio#17](https://github.com/pedrobtz/qio/issues/17)).
- **`qio`**: a consumer in a later version (§14): a Parquet file exposed
  as a stream, so Parquet columns reach R through the same registry.
- **`zumime`** (RFC 0040): already names the `ARROW1` and `FEA1`
  signatures; nothing to add.
- **`quak`**: a consumer. DuckDB results over Azure storage arrive as
  streams; the exact-types rule is what makes `BIGINT` and `HUGEINT`
  columns survive.

## 4. Architecture

Five layers, the first vendored:

1. **nanoarrow** (`src/nanoarrow/`, §7). The C Data Interface helpers
   (`ArrowSchemaInit*`, `ArrowArrayView*`, the validation routines) and
   the IPC decoder and encoder with its generated FlatBuffers header.
   Compiled with `NANOARROW_NAMESPACE` set to `zuarrow` so its symbols
   cannot clash with the `nanoarrow` package's when both are loaded in
   one session, and hidden anyway (R3).
2. **Handles** (`src/zar_xptr.c`). External pointers in the layout
   nanoarrow's `r.h` documents: the struct is `malloc()`ed, a `NULL`
   `release` means unset, the finalizer calls `release` when set, an
   array pointer's tag holds its schema pointer, the protected field holds
   whatever keeps the memory alive (D6). The classes are
   `c("zuarrow_schema", "nanoarrow_schema")` and likewise for array and
   stream (D7), so `inherits()` in either package says yes and S3 methods
   do not collide.
3. **Conversion kernels** (`src/zar_to_r.c`, `src/zar_from_r.c`). One
   function per Arrow type family over an `ArrowArrayView`, filling an R
   vector allocated once at the known length, and the reverse building
   buffers from an R vector. The kernels never call back into R; a
   column that needs a registered handler is left for layer 5, which
   calls the handler with the array handle.
4. **IPC** (`src/zar_ipc_read.c`, `src/zar_ipc_write.c`,
   `src/zar_codecs.c`). The reader detects the framing by the first
   bytes, walks the footer or the message sequence, validates every
   message and body against the limits before touching the body, hands
   the decoder and encoder compression functions that call `zukomp`'s
   table (`src/zar_codecs.c` is that adapter), and exposes the result as
   a stream handle. The writer takes a stream handle and emits either
   framing, deterministically (§6.8).
5. **The registry and the R surface** (`R/`). The registry is an
   environment keyed by dispatch key (§6.10); the R surface is the
   functions of §5 and the S3 methods on the `zuarrow_*` classes. The
   only R code on the hot path is the per-column dispatch.

Layers 3 and 4 compile without R under `ZAR_STANDALONE`, with a codec
adapter that leaves bodies compressed, which is how the fuzz target of §9
builds them against the `arrow-testing` crash corpus: it exercises
framing and validation, not the codecs.

## 5. Public R API (v0.1.0 shape)

```r
# handles: the same layout nanoarrow uses (D6)
arrow_schema(x)                          # from an R object, a format string,
                                         # or any handle; prints the tree
arrow_array(x, schema = NULL)            # one vector or data frame -> array
arrow_stream(x, batch = 65536L, schema = NULL)   # data frame -> stream
# back to R
arrow_to_r(x, to = NULL,
           lossy = c("error", "character", "warn", "allow"))
as.data.frame(stream, ...)               # S3, same arguments
as.vector(array, ...)                    # S3
arrow_next(stream, ...)                  # one batch as a data frame, or NULL
# the IPC formats
arrow_read(x, columns = NULL, lazy = FALSE, to = NULL,
           lossy = "error", limits = arrow_limits())
arrow_write(data, x, format = c("file", "stream"),
            compression = c("none", "lz4", "zstd"), level = NULL,
            batch = 65536L, dictionary = TRUE, metadata = NULL)
arrow_limits(max_message = 2^31 - 1, max_depth = 64L,
             max_batch_rows = 2^31 - 1, max_bytes = Inf)
# validation, comparison, metadata (§6.11)
arrow_validate(x, level = c("full", "default", "minimal"))
arrow_equal(x, y, metadata = TRUE)
arrow_metadata(x)                        # named character vector
arrow_metadata(schema) <- value
format(schema)                           # type notation, e.g. "int64"
# the registry
arrow_register(key, to = NULL, from = NULL, class = NULL, package = NULL)
arrow_unregister(key)
arrow_registry()                         # data frame: key, class, package, exact
arrow_types()                            # the built-in table of §6.2
zuarrow_info()
```

`x` in `arrow_read()` is a path, a raw vector or a connection. With
`lazy = TRUE` it returns a stream handle whose batches are decoded on
`arrow_next()`; otherwise a data frame. `arrow_write()` returns `x`
invisibly for a path or connection, or the raw vector when `x` is
`NULL`.

### Results

`arrow_to_r()` on an array returns a vector of the registered or built-in
R type; on a stream or struct array it returns a plain `data.frame`, one
column per field, nested data frames for struct children, list columns
for lists, and factors for dictionaries. Nothing carries a zuarrow class:
the result drops into `dplyr`, `data.table` and `write.csv()` unchanged.
Schema-level metadata is the `arrow_metadata` attribute of the frame;
field-level metadata and extension names are attributes of the column
(§6.6).

## 6. Semantics

### 6.1 Handles

A handle owns one struct. A schema handle may be read any number of
times. An array handle is read any number of times but its buffers are
owned by whoever produced it: an array from DuckDB is valid until its
`release`, which the finalizer calls when the handle is collected. A
stream handle is consumed once; after the producer returns an array with
`release == NULL` the stream has ended, and `arrow_next()` returns `NULL`
from then on. Streams are read and released on the main thread only,
because `get_next` may call into the producer.

Handles from `nanoarrow`, `arrow` (through its `as_nanoarrow_*` methods),
`duckdb`, `polars`, ADBC drivers and `reticulate` (through nanoarrow's
PyCapsule support) are accepted wherever a zuarrow handle is: the test is
`inherits(x, "nanoarrow_array_stream")` and the read is through the
`r.h` accessors' documented layout, not through nanoarrow's code.
Handles zuarrow makes are accepted by those packages for the same reason,
with the delayed S3 registrations of §3 covering nanoarrow's generics.

### 6.2 The type table

Built in, exact in both directions, needing no registration:

| Arrow | R | Notes |
| --- | --- | --- |
| `null` | `logical` of `NA` | export: a logical that is all `NA` stays `bool` |
| `bool` | `logical` | |
| `int8`, `int16`, `int32` | `integer` | `int32` `INT_MIN` is lossy (§6.9) |
| `uint8`, `uint16` | `integer` | |
| `uint32` | `double` | exact: every value fits |
| `half_float`, `float`, `double` | `double` | half floats: see below |
| `utf8`, `large_utf8`, `utf8_view` | `character` | embedded NUL is lossy |
| `binary` and variants, `fixed_size_binary` | list of `raw` | see below |
| `date32` | `Date` | |
| `timestamp[s]`, `timestamp[ms]` | `POSIXct` | exact within ±2⁵³ ms |
| `struct` | `data.frame` column | §6.4 |
| `list`, `large_list`, `list_view`, `large_list_view` | list column | §6.4 |
| `fixed_size_list` | list column; matrix on export when asked | §6.4 |
| `map` | list column of two-column data frames | §6.4 |
| `dictionary` | `factor`, when the values are strings | §6.5 |
| `run_end_encoded` | the decoded values' type | read only |
| `arrow.bool8` extension | `logical` | §6.6 |

Half floats are widened by the rule `zufast` ships, reimplemented locally
since there is no `LinkingTo`. `binary`, `large_binary` and `binary_view`
all read as a list of raw vectors; `fixed_size_binary` keeps its width as
the `arrow_width` attribute so export restores the type.

Built in but **not exact**, so they error under the default policy and
name the family package that makes them exact:

| Arrow | Lossy R form (`lossy = "allow"`) | Exact target |
| --- | --- | --- |
| `int64`, `uint64` | `double`; `integer64` when `bit64` is loaded | `zuint` |
| `decimal32`, `decimal64`, `decimal128`, `decimal256` | `double` | `decimal` |
| `timestamp[us]`, `timestamp[ns]` | `POSIXct` | `zutempo` |
| `date64` | `POSIXct` | `zutempo` |
| `time32`, `time64` | `difftime` | `zutempo` |
| `duration` | `difftime` | `zutempo` |
| `interval` (all three) | none; always an error | `zutempo` |
| `dense_union`, `sparse_union` | none; always an error | none planned |

Every row but the last two also has an exact character form, which
`lossy = "character"` selects (§6.3).

On export, R types map by class: `integer` to `int32`, `double` to
`double`, `logical` to `bool`, `character` to `utf8` (`large_utf8` when
the total bytes exceed 2³¹ − 1), `Date` to `date32`, `POSIXct` to
`timestamp[us]` with the `tzone` attribute as the zone (`UTC` when
absent; D10), `difftime` to `duration` at its unit, `factor` to
`dictionary<int32, utf8>`, a list of raw vectors to `binary`, a list of
same-typed vectors to `list<T>`, a matrix to `fixed_size_list` when
`arrow_array()` is told so, a `data.frame` column to `struct`. A
registered class goes through its `from` handler. Any other class errors
as `zuarrow_type_error` naming the class.

### 6.3 Exact or error

A conversion is **exact** when every non-null value is represented
without change and every null becomes `NA`, and the reverse conversion
with the same schema reproduces the input bytes. The `lossy` argument
decides what happens otherwise:

- `"error"` (default): `zuarrow_lossy_error`, with the column name, the
  Arrow type, the first offending row where one exists (an `int64` of
  2⁵³ + 1), and the exact target: the registered class if one exists, or
  the family package that would register it.
- `"character"`: the value's canonical text, which is exact, for every
  type in §6.2's second table except intervals and unions: integers as
  digits, decimals with their scale's digits through nanoarrow's decimal
  helpers, timestamps and `date64` as ISO 8601 at the type's precision
  with the zone, times as `HH:MM:SS` with the fractional digits of the
  unit, durations as the count with the unit in the `arrow_unit`
  attribute. The column carries the Arrow format string in the
  `arrow_type` attribute so export restores the type. This is how a
  session without `zuint`, `decimal` or `zutempo` sees the data without
  losing it (D16).
- `"warn"`: the lossy form of §6.2 with a `zuarrow_lossy_warning`, once
  per column, which is nanoarrow's behaviour.
- `"allow"`: the lossy form, silently.

The check is by schema where the schema decides it (`decimal`,
`timestamp[ns]`, `interval`) and by value where only the values decide
it (`int64` within ±2⁵³, `int32` without `INT_MIN`, `utf8` without NUL).
The value scan is one pass in C and is skipped when the schema already
says exact.

`to` overrides the table for named columns: `to = list(id =
zuint::int64())` says what `id` must become, and a target that cannot
take the column is a `zuarrow_type_error`, never a silent fallback.

### 6.4 Nested types

A `struct` becomes a `data.frame` column of the same row count, nested as
base R allows (`df$pos$x`), and `nrow()` of the parent is unaffected.
A `list<T>` becomes a plain list column whose elements are vectors of
`T`'s R form, with `NULL` for a null list and a zero-length vector for an
empty one; no `vctrs::list_of` because the package has no `Imports` and
the class carries no information the element types do not. `large_list`
and the view variants read the same way; export always writes `list`
unless the offsets need 64 bits. A `fixed_size_list<T, n>` reads as a
list column by default, and as an `n`-column matrix when
`to = arrow_matrix()` asks, which is the only way a matrix is produced. A
`map<K, V>` reads as a list column of two-column data frames named `key`
and `value`, in the map's order, with the `keys_sorted` flag kept as an
attribute. Nesting depth is bounded by `max_depth` (§6.7).

### 6.5 Dictionaries

A `dictionary<index, utf8>` whose dictionary has at most 2³¹ − 1 entries
becomes a `factor` with the dictionary as levels in dictionary order and
`ordered` from the `ARROW_FLAG_DICTIONARY_ORDERED` flag. A dictionary of
any other value type is decoded to the value type's R form, because a
factor cannot carry it. On export a `factor` becomes
`dictionary<int32, utf8>` with its levels as the dictionary, and
`ordered = TRUE` sets the flag. A dictionary in a stream may be replaced
or appended by delta batches between record batches (§6.7); within one
decoded batch the levels are those in force when the batch arrived, and
`rbind()`ing two batches with different levels is the caller's problem,
which the eager reader solves by decoding to the union of levels when
`lazy = FALSE`.

### 6.6 Extension types

An extension field carries `ARROW:extension:name` and
`ARROW:extension:metadata` in its field metadata. A registered name
(§6.10) is converted by its handler. An unregistered name is converted
as its storage type under the usual exactness rule, and the R column
keeps the name and metadata as the attributes `arrow_extension` and
`arrow_extension_metadata`, so exporting the column restores the field
exactly. Nothing is lost and nothing is warned about, because the bytes
are intact; a caller who wants to know can look at the attribute.
`arrow.bool8` is the one canonical extension built in, since `logical` is
its exact form; `arrow.uuid`, `arrow.json`, `arrow.opaque` and the
tensor extensions pass through as storage with the attribute.

### 6.7 Reading IPC

- **Framing.** The first six bytes `ARROW1` mean the file format: the
  footer is read from the end (its length in the four bytes before the
  trailing magic), and the schema, dictionary blocks and record batch
  blocks come from the footer, so a file is random access and
  `columns` can skip buffers. Otherwise the input is a stream: messages
  are read in order, each a continuation marker, a 32-bit length, a
  FlatBuffers `Message` and an 8-byte-aligned body. A stream ends at an
  end-of-stream marker or at end of input.
- **Sources.** A path is opened and read with `fread()`; a raw vector is
  read in place; a connection is read through R's connection API in
  blocks, which is how a gzipped stream or a socket arrives. The file
  format on a non-seekable connection is read by buffering to the end,
  with a message when the buffer exceeds `max_bytes`.
- **Laziness.** `lazy = TRUE` returns a stream handle and decodes one
  record batch per `arrow_next()`; `lazy = FALSE` decodes everything and
  returns one data frame, concatenating batches in C.
- **Column selection.** `columns` is a character or integer vector of
  top-level fields; in the file format the unselected buffers are never
  read, in the stream format they are skipped after the message is
  parsed.
- **Compression.** Record batch bodies with `LZ4_FRAME` or `ZSTD`
  compression are decompressed buffer by buffer through `zukomp`'s
  `lz4-frame` and `zstd` codecs, with the 8-byte uncompressed-length
  prefix the specification defines passed as the expected size and the
  `-1` sentinel for an uncompressed buffer honoured. `zukomp`'s
  `max_output` limit binds, so a lying prefix is a `zuarrow_limit_error`.
- **Dictionaries.** Dictionary batches before the first record batch, and
  delta batches between record batches, are applied as the specification
  says; a replacement dictionary in the file format is an error, as the
  format forbids it.
- **Newer layouts.** Run-end-encoded arrays are decoded to their value
  type; string-view, binary-view and list-view arrays are converted by
  copying through their views. nanoarrow's IPC decoder stops short of
  all three (#833, #824), so the vendored copy carries a patch that maps
  them, kept in the patch list and offered upstream (D17). The
  `cpp-21.0.0` golden cases are the proof.
- **Validation.** Every message is validated before its body is touched:
  the FlatBuffers table is verified, every buffer offset and length is
  checked against the body length, every offsets buffer is checked
  monotonic and in range, dictionary indices are checked against the
  dictionary length, and `max_depth`, `max_message`, `max_batch_rows`
  and `max_bytes` are enforced. The check-then-build shape is
  `zucbor`'s: nothing is allocated on the R heap for a message that
  fails. Each decoded array then passes nanoarrow's full validation
  level, which checks buffer contents and not only sizes, as the library
  recommends for untrusted input (§6.11). The `arrow-testing` crash
  corpus (§9) is the regression set.

### 6.8 Writing IPC

- **Input.** A data frame is batched by `batch` rows (default 65 536,
  `arrow`'s default) into a stream; an array or a stream is written as
  it is. Each batch is built in C from the data frame's columns without
  copying the whole frame.
- **Framing.** `format = "file"` writes the magic, the schema message,
  dictionary batches, record batches, the footer and the trailing magic;
  `format = "stream"` writes the schema and batches and the end-of-stream
  marker. A path ending in `.arrows` defaults to the stream format, any
  other path to the file format.
- **Alignment.** Bodies are padded to 8 bytes, the specification's
  requirement, not the 64 it recommends, so output matches `arrow`'s
  default and is as small as the format allows (D11).
- **Compression.** `none` by default (D9); `lz4` means `LZ4_FRAME` and
  `zstd` means `ZSTD`, each buffer compressed separately through
  `zukomp` with the length prefix, and a buffer that does not shrink
  written uncompressed with the `-1` sentinel. `level` is the codec's
  own scale, as `zukomp` defines it.
- **Dictionaries.** `dictionary = TRUE` writes factors as dictionary
  fields with one dictionary batch per factor before the first record
  batch; `FALSE` writes them as `utf8`. No delta dictionaries are
  written.
- **Metadata.** `metadata` is a named character vector written as schema
  custom metadata; column attributes `arrow_extension`,
  `arrow_extension_metadata` and `arrow_field_metadata` are written as
  field metadata.
- **Determinism.** The same R input and options produce byte-identical
  output on every platform: fixed message ordering, no timestamps, no
  padding bytes left uninitialised, FlatBuffers built by the vendored
  encoder in a fixed field order, and codec output pinned by the `zukomp`
  version the package was checked against.

### 6.9 Nulls

Arrow's null is a validity bit; R's missing value is a sentinel. Both
directions:

- `NA_integer_` is `INT_MIN`, so an Arrow `int32` holding `INT_MIN` as a
  value cannot be distinguished from `NA` in R: it is lossy and errors
  by default, naming the row. `int8`, `int16`, `uint8` and `uint16`
  cannot hold it and are exact.
- `NA_real_` is a NaN with a payload; an Arrow `double` NaN is read as
  `NaN`, and an Arrow `double` whose bits equal R's `NA_real_` is read as
  `NA`: the one lossy edge in doubles, documented as RFC 0009 documents
  its `UINT64_MAX` edge, and the value scan does not look for it.
- `NA_character_` is null; the string `"NA"` is a value. `NA` in a
  `logical` is null.
- A null `struct` row is `NA` in every child column, which is how base
  R can hold it; a null `list` element is `NULL`.
- On export, every sentinel becomes a null bit and the data slot holds
  zero, so output is deterministic (§6.8).

### 6.10 The registry

A registration binds a **dispatch key** to handlers. The key is one of:

- an Arrow format string, exactly (`"l"` for `int64`) or as a prefix
  pattern for parameterised types (`"d:*"` for every decimal, `"tsn:*"`
  for every nanosecond timestamp);
- an extension name (`"r.decimal"`), which takes precedence over the
  storage type's key;
- an R class, for export (`class = "zuint_int64"`).

`to` is a function of `(array, schema)` receiving the handles and
returning an R vector, which lets a registering package implement it in C
through the `r.h` layout; `from` is a function of `(x)` returning an
array handle. A registration declares `exact = TRUE` and is trusted;
the family rule is that a registration may make a lossy default exact
and may never make an exact default lossy, and `arrow_registry()` shows
`exact` so a reviewer can see what is claimed. Registration is
session-scoped, done in the registering package's `.onLoad()` when
zuarrow is installed, and removed on its unload. A later registration
for the same key replaces the earlier one with a message naming both
packages.

### 6.11 Validation, comparison and metadata

Four things the C library has and the nanoarrow binding does not reach:

- **`arrow_validate(x, level)`** runs nanoarrow's validation at
  `minimal` (buffer sizes), `default` (offsets and lengths) or `full`
  (buffer contents, including UTF-8 and dictionary indices) on an array
  or every batch of a stream, returning `TRUE` or raising
  `zuarrow_format_error` with the path to the offending child. IPC input
  always gets `full` (§6.7); handles from another producer get `default`
  on conversion and `full` on request.
- **`arrow_equal(x, y, metadata = TRUE)`** compares two arrays or two
  streams value by value through nanoarrow's array comparison, nulls
  equal to nulls, and schemas including metadata unless told otherwise.
  It is what the oracles of §9 use and what a consumer's tests want.
- **`arrow_metadata(x)`** reads schema or field metadata as a named
  character vector through nanoarrow's metadata reader, and its
  replacement form writes it through the builder on a schema handle, so
  custom metadata is a first-class value rather than an attribute
  convention. Binary metadata values are kept as raw.
- **`format(schema)`** prints the type notation Arrow's own tools use
  (`int64`, `timestamp[ns, tz=UTC]`, `list<item: double>`) through
  nanoarrow's schema printer, which is what #370 asks the binding for.
  Input stays format strings and R objects in v0.1.0; parsing the
  notation is §14.

## 7. Vendored code

| Component | Version | Licence | Where |
| --- | --- | --- | --- |
| nanoarrow core (`common/`) | 0.9.0 | Apache-2.0 | `src/nanoarrow/` |
| nanoarrow ipc (`ipc/`) | 0.9.0 | Apache-2.0 | `src/nanoarrow/ipc/` |
| nanoarrow testing header | 0.9.0 | Apache-2.0 | `tests/` harness only |

Sizes at the pinned tag: the core is about 290 KB of C and inline
headers; ipc is about 230 KB plus the 1.5 MB generated FlatBuffers
header. The testing header (`nanoarrow_testing.hpp`, with the C++
wrapper `nanoarrow.hpp` it includes) is the reader, writer and comparison
for the Arrow integration JSON format; it is compiled into the test
harness under `tests/` and never into `zuarrow.so`, so the package's
compiled code stays C (D18). lz4 and zstd are not vendored: they come
from `zukomp` (D2).

Not vendored: nanoarrow's `device/` and `integration/` directories, the
rest of `hpp/`, and flatcc's runtime beyond the pieces the generated
header needs. `tools/update-vendor` fetches the pinned tag, copies the
listed files, applies the patch list (one expected patch at writing: the
IPC decoder's mapping for run-end-encoded and view layouts, §6.7, offered
upstream against #833 and #824; nanoarrow already builds under `-Wall
-pedantic` with `-fvisibility=hidden` as the R package itself proves) and
records the upstream commit in `inst/COPYRIGHTS`. The `NANOARROW_NAMESPACE` build
flag renames every exported nanoarrow symbol, which is the mechanism the
nanoarrow project itself provides for exactly this situation; R3's hidden
visibility makes it belt and braces.

Apache-2.0 code inside an MIT package is permitted by the Apache licence
provided its text and `NOTICE` travel; `inst/COPYRIGHTS` carries both and
`Authors@R` names the Apache Software Foundation with `role = "cph"`,
following RFC 0040's D8 and CRAN's October 2026 correspondence on
copyright holders (D14).

## 8. Errors

Every condition inherits from `zuarrow_error`; tests assert on class.

| Class | Raised when |
| --- | --- |
| `zuarrow_type_error` | an unmapped R class, or a `to` the column cannot fit |
| `zuarrow_lossy_error` | a lossy conversion under `lossy = "error"` (§6.3) |
| `zuarrow_lossy_warning` | the same under `lossy = "warn"` |
| `zuarrow_format_error` | invalid IPC bytes (§6.7's validation list) |
| `zuarrow_limit_error` | a size, depth or total over `arrow_limits()` |
| `zuarrow_codec_error` | a `zukomp` codec failure, or an unknown codec id |
| `zuarrow_io_error` | a path cannot be opened, or a connection fails |
| `zuarrow_handle_error` | a released or consumed handle, or a foreign pointer |
| `zuarrow_registry_error` | a malformed key or handler in `arrow_register()` |
| `zuarrow_dependency_error` | a target names an absent suggested package |

`arrow_schema()` on any handle never raises on content; `arrow_next()`
after the end returns `NULL` rather than raising.

## 9. Testing

`testthat` 3e. One file per subsection of §6. Four oracles, none a
dependency:

1. **The golden files.** `apache/arrow-testing`'s
   `data/arrow-ipc-stream/integration/` holds, per format version
   (`0.14.1`, `0.17.1`, `1.0.0-littleendian`, `1.0.0-bigendian`,
   `2.0.0-compression`, `4.0.0-shareddict`, `cpp-21.0.0`), one
   `.arrow_file`, one `.stream` and one `.json.gz` per case: primitives,
   datetime, decimal and decimal256, dictionaries including unsigned and
   nested, duplicate field names, extension types, intervals, maps,
   nested and large-offset lists, nulls, custom metadata, and
   compression. For every case the file and the stream must decode to
   the same R value, and both must equal the JSON, read by nanoarrow's
   integration-testing reader and compared with its comparison class
   (§7), which is the code Arrow's own cross-implementation suite uses.
   Cases whose types are lossy without the family packages are read
   with `lossy = "character"` and compared with the JSON's own text
   encoding of integers and decimals, and again exactly when `zuint`,
   `decimal` and `zutempo` are installed. The `cpp-21.0.0` directory's
   `binary_view`, `list_view` and `run_end_encoded` cases must decode
   (§6.7). The `union` case must raise `zuarrow_lossy_error` without
   crashing. The big-endian directory must error cleanly, since v0.1.0
   reads little-endian only (D13).
2. **The crash corpus.** `data/arrow-ipc-file/` and
   `data/arrow-ipc-stream/` hold ClusterFuzz test cases that crashed
   earlier readers. Each must raise `zuarrow_format_error` or
   `zuarrow_limit_error`, never crash, under sanitizers.
3. **`nanoarrow` 0.9.0.** A handle made by zuarrow is read by nanoarrow
   and the reverse, for every built-in type, through `as.data.frame()`
   on both sides; a stream zuarrow writes is read by `read_nanoarrow()`
   and the reverse.
4. **`arrow` 25.** `arrow::write_feather()` with each compression is read
   by `arrow_read()`; `arrow_write()` with each option is read by
   `arrow::read_feather()` and `arrow::read_ipc_stream()`; the
   round-trip frame is identical for the exact types.

Property tests: for every built-in exact type and random values with
nulls, `arrow_to_r(arrow_array(x))` is identical to `x`,
`arrow_equal(arrow_array(x), arrow_array(x))` holds, `arrow_validate()`
at `full` passes on every array zuarrow builds, and the bytes of
`arrow_write(x, NULL)` are identical across the CI legs. The fuzz target
under `ZAR_STANDALONE` runs the crash corpus and mutated golden files
through layers 3 and 4 and checks: no crash, no read past the buffer, no
allocation before validation passes. From the family (R3): `test-abi.R`,
that the shared object exports `R_init_zuarrow` only, and a test that no
symbol named `Arrow*` is exported, which is the `NANOARROW_NAMESPACE`
check.

The fixtures are fetched by `tools/fetch-fixtures` at a pinned
`arrow-testing` commit into `tests/testthat/fixtures/`, which
`.Rbuildignore` and `.gitignore` exclude; the tests skip with a message
when the directory is absent, and the CI test job runs the fetch first.

## 10. Performance targets

Measured by `tools/run-benchmarks`, recorded in `.agents/benchmarks.md`,
with the baseline run in Stage 0 before any zuarrow code exists. The
input is a data frame of 10⁷ rows with ten columns: four `double`, two
`integer`, two `character` of ten bytes, one `factor` of a hundred
levels, one `Date`.

| Operation | Target |
| --- | --- |
| `arrow_read()`, plain file | within 1.5× of `arrow::read_feather()` |
| `arrow_read()`, lz4 file | within 1.5× of `arrow::read_feather()` |
| `arrow_read()`, stream | within 1.5× of `nanoarrow::read_nanoarrow()` |
| `arrow_write()`, plain file | within 1.5× of `arrow::write_feather()` |
| `arrow_to_r()`, 10⁷ doubles | under 30 ms; one copy |
| `arrow_array()`, 10⁷ strings | within 2× of `nanoarrow`'s constructor |
| `arrow_next()` per 65 536-row batch | under 5 ms for the ten columns |

The `nanoarrow` figures include its `as.data.frame()`, since that is
where its conversion happens.

The honest ceiling is `arrow`, which reads through libarrow's own IPC
reader with no R-level work; a vendored C reader that copies once should
sit beside it. The floor is `nanoarrow`, which the stream path should
match since the decoder is the same code.

## 11. Roadmap

Stages run the quick CI profile unless marked `full`. Each is one pull
request, merged on green. Riskiest first: the handle layout and the
vendored build before the type table, the type table before IPC.

| Stage | Delivers | Exit criterion |
| --- | --- | --- |
| 0 | repository, CI, vendored code, baseline | builds on every leg; §10 bar |
| 1 (`full`) | handles, `arrow_schema()`, §6.11 tools | §6.1, §6.11; oracle 3 |
| 2 | type table, `arrow_to_r()`, `arrow_array()` | §6.2, §6.3, §6.9 |
| 3 | nested, dictionaries, extensions, registry | §6.4 to §6.6, §6.10 |
| 4 (`full`) | IPC reader, codecs, layouts, limits | §6.7; oracles 1, 2 |
| 5 | IPC writer, determinism, benchmarks | §6.8; oracle 4; §10 |
| 6 (`full`) | README, article, release preparation | §12 |

Stage 0 writes `tools/update-vendor`, pins the nanoarrow tag, records
the `zukomp` release that ships the codecs as the `LinkingTo` floor,
builds with `NANOARROW_NAMESPACE`, and times
`arrow::read_feather()`, `nanoarrow::read_nanoarrow()` and
`qio::read_parquet()` on the §10 input so the bar is on record. Stage 1
is `full` as the first compiled code of substance and because the
handle layout is the decision everything else rests on. Stage 3 lands a
registration in `decimal`'s repository as the first consumer, which is
R10's consumer fixture in spirit. Stage 4 carries the decoder patch for
the newer layouts (§6.7) and opens the upstream pull request before the
stage closes. Stage 6 writes `cran-comments.md`, adds the Apache
Software Foundation to `Authors@R` with `role = "cph"`, runs the full
profile and records the dates.

## 12. Acceptance criteria for v0.1.0

- Every behaviour in §6 and §8 has a passing test.
- The four oracles of §9 pass: every golden case in the little-endian
  directories, every crash case rejected cleanly, interchange with
  `nanoarrow` for every built-in type, and round trips with `arrow` for
  every compression.
- The fuzz target runs one hour clean under `ZAR_STANDALONE` with
  sanitizers.
- `arrow_write()` of the §10 input gives byte-identical files on the
  Linux, macOS and Windows CI legs.
- Every `cpp-21.0.0` case with a run-end-encoded or view layout decodes,
  and the decoder patch has an upstream pull request.
- `lossy = "character"` reproduces the JSON text of every golden integer
  and decimal case.
- `R CMD check --as-cran` is clean on all r-actions legs; `zukomp` is
  the only `Imports`; the shared object exports `R_init_zuarrow` only
  and no `Arrow*` symbol; `DESCRIPTION` names the Apache Software
  Foundation as a copyright holder and `inst/COPYRIGHTS` states the
  nanoarrow commit.
- `decimal` registers with zuarrow and its golden cases decode exactly.
- `.agents/benchmarks.md` holds a number for every row of §10, met or
  not.
- Seven stages. A stage that needs a second pull request moves scope to
  §14, not the release.

## 13. Decisions

All are **(C)**: this RFC decides them and the maintainer may overturn
them. None was discussed before writing.

- **D1 (C).** Vendor nanoarrow's core and ipc components rather than
  write the C Data Interface helpers and the IPC codec, or link to the
  `nanoarrow` package. The helpers are the Arrow project's own
  reference, the IPC decoder has a fuzz history, and the generated
  FlatBuffers header is the one piece of the format nobody should hand
  write. Linking to the package is ruled out because its `LinkingTo`
  header ships structs and accessors only (§1.3).
- **D2 (C).** The IPC codecs come from `zukomp`, which ships `zstd` and
  `lz4-frame` in its core from the release zukomp#55 tracks; zuarrow
  takes `Imports: zukomp` and `LinkingTo: zukomp` and vendors neither
  codec. The family then has one copy of each to update, `qio` moves
  onto the same copy (qio#17), and the promise that a compressed file
  opens everywhere holds because `Imports` are mandatory. This replaces
  the first draft's plan to vendor both, which also mis-stated what
  `qio` ships: its lz4 is the block API, and Arrow needs the frame API.
- **D3 (C).** One registry for the family's exact types, populated by
  the typed packages at load, replacing the three bridges in flight
  (§1.3). zuarrow knows nothing about `zuint`, `decimal` or `zutempo`
  beyond the package name it prints in a `zuarrow_lossy_error`.
- **D4 (C).** `lossy = "error"` is the default. The package's reason to
  exist is that no bridge in R errors on loss today; a default of `warn`
  would make it nanoarrow with a different prefix.
- **D5 (C).** `zukomp` is the only `Imports`. `bit64` is consulted only under
  `lossy = "allow"` and only when already loaded (§6.2); `vctrs` is not
  used for list columns (§6.4).
- **D6 (C).** Handles use the layout nanoarrow's `r.h` documents:
  `malloc()`ed struct, `NULL` release means unset, tag holds the schema,
  protected field holds dependencies. The layout is the published
  contract of the Arrow project's own R binding, and adopting it is what
  makes DuckDB, Polars, ADBC, `arrow` and `nanoarrow` objects usable
  without conversion.
- **D7 (C).** The class vector is `c("zuarrow_<kind>", "nanoarrow_<kind>")`
  and zuarrow defines S3 methods on the first class only, so loading both
  packages overwrites no method and `inherits()` works in both.
- **D8 (C).** The first release copies once, in C; zero-copy views wait
  for §14 and reuse RFC 0009's ALTREP classes rather than inventing
  parallel ones.
- **D9 (C).** `compression = "none"` on write, so a file zuarrow writes
  by default opens in every reader, including a `nanoarrow` built
  without system codecs. `arrow`'s default of lz4 is one argument away.
- **D10 (C).** `POSIXct` exports as `timestamp[us]`, because a double of
  seconds carries microseconds for every date in practical use and
  `arrow` makes the same choice; the zone is the `tzone` attribute or
  `UTC`. Nanoseconds are `zutempo`'s.
- **D11 (C).** Bodies are padded to 8 bytes, the specification's
  requirement and `arrow`'s default, not the 64 it recommends for SIMD.
- **D12 (C).** The R prefix is `arrow_`, avoiding the names `arrow`
  exports under it (`arrow_table`, `arrow_info`, `arrow_available` and
  the rest, listed by Stage 0) except `arrow_array()`, which zuarrow also
  needs and which is documented as a known mask (§15 Q3); the condition
  root is `zuarrow_error`, the internal C prefix `zar_`.
- **D13 (C).** Little-endian only in v0.1.0. The format's `endianness`
  field is read and a big-endian schema is a `zuarrow_format_error`; no
  CRAN platform in the r-actions matrix is big-endian, and byte swapping
  every buffer is work with no consumer.
- **D14 (C).** MIT for zuarrow's own code, with the Apache-2.0, BSD-2
  and BSD-3 texts and notices in `inst/COPYRIGHTS` and the Apache
  Software Foundation as `cph`, following RFC 0040's D8.
- **D15 (C).** Performance targets (§10) are measured and recorded but
  do not gate v0.1.0; the oracles do.
- **D16 (C).** `lossy = "character"` is the exact fallback for a session
  without the typed packages, placed between `error` and `warn` because
  it loses nothing. The alternative, an `integer64`-style class of
  zuarrow's own, would be a fourth exact integer type in the family.
- **D17 (C).** The newer layouts are read in v0.1.0 by patching the
  vendored IPC decoder rather than waiting for nanoarrow #833 and #824,
  because the golden corpus already carries them and a reader that
  refuses a valid file is the failure this package exists to remove. The
  patch is offered upstream in the same stage.
- **D18 (C).** The integration-testing header is vendored for the test
  harness only, so the golden-file oracle uses Arrow's own JSON reader
  and comparison rather than a reimplementation, and `zuarrow.so` stays
  C.

## 14. Later versions, in the order they are expected

- **A C table**: `inst/include/zuarrow.h` and
  `R_GetCCallable("zuarrow", "zuarrow_api_v1")` with the conversion
  kernels, the registry lookup and the handle constructors, so `zuint`,
  `zutempo` and `qio` convert without an R round trip; consumer fixture
  per R10.
- **Zero-copy views**: `arrow_to_r(copy = FALSE)` wrapping `double`,
  `int32` and, through `zuint`'s classes, `int64` and `uint64` buffers as
  ALTREP vectors whose `data2` holds the release callback, as RFC 0009
  §9.1 specifies; strings through an ALTREP `STRSXP` as nanoarrow does.
- **Memory-mapped files**: `arrow_read(mmap = TRUE)` over the file
  format, through `zufs` when it exists, so a file larger than memory is
  a data frame of views.
- **`qio` as a producer**: a Parquet file as a stream, so Parquet columns
  pass through the registry; decided in `qio`'s repository.
- **`zutable` from a stream**: the locked schema taken from the Arrow
  schema; decided in `zutable`'s repository.
- **A DuckDB helper**: once the `duckdb` R package's most direct route to
  an `ArrowArrayStream` is verified (RFC 0031 §7.3 left it open),
  `arrow_duckdb(con, sql)` returning a stream with the registry applied.
- **Writing run-end-encoded and view types**, if a consumer produces
  them.
- **Arrow's cross-implementation integration suite**: the `integration/`
  hooks that let archery drive zuarrow as an IPC producer and consumer
  beside the C++, Rust, Go and Java implementations.
- **A chunked vector class** over a list of arrays, the interchange class
  nanoarrow's #331 and #219 discuss, if `zutable` wants columns that
  stay in Arrow memory.
- **Parsing the printed type notation** in `arrow_schema()` (§6.11).
- **Big-endian reading**, if a platform asks.

## 15. Open questions

- **Q1.** At each `nanoarrow` release: has its binding gained the file
  framing (#728), dictionary writing (#622), the newer layouts (#617,
  #833, #824), bundled codecs or an exact-targets registry? If all of
  them, §1.3 says zuarrow shrinks to the registry and the C table.
- **Q2.** Should the eager reader union dictionary levels across delta
  batches (§6.5) or error, given that a factor whose levels changed
  mid-stream is a surprise either way?
- **Q3.** Does `arrow_array()` mask `arrow::arrow_array()` acceptably, or
  should the constructor be `arrow_from_r()` to keep the two packages
  free of masks in one session?
- **Q4.** Should `lossy = "warn"` be what `as.data.frame()` uses, since
  the S3 generic is what tidyverse code calls implicitly and an error
  from `dplyr::collect()` on a `BIGINT` column may be more friction than
  the rule is worth? This RFC says no: the generic takes the same
  default.
- **Q5.** Is v0.1.0 a CRAN submission or a GitHub release? The board's
  `CRAN intent` field records the answer; this RFC assumes `Planned`.
- **Q6.** Should `arrow_validate()` at `default` run on every foreign
  handle before conversion, or only `minimal`, once Stage 2 has measured
  the cost on a 10⁷-row stream from DuckDB?

## 16. What this RFC does not decide

The exact form of the `to` targets beyond named prototypes (a schema
object, a format string, or both); the printing of handles and schemas;
whether `arrow_registry()` lists built-in rows or registered ones only;
the wording of condition messages beyond their classes and the fields
§6.3 requires; the `zukomp` floor version, which Stage 0 records once
that release exists; and the article's second example.
