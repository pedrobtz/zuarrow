# Package information

Reports the versions zuarrow is built from: its own, the vendored
'nanoarrow' C library's, and the IPC metadata version it writes.

## Usage

``` r
zuarrow_info()
```

## Value

A named list with `zuarrow`, `nanoarrow` and `ipc_metadata`.

## Examples

``` r
zuarrow_info()
#> $zuarrow
#> [1] "0.0.0.9000"
#> 
#> $nanoarrow
#> [1] "0.9.0"
#> 
#> $ipc_metadata
#> [1] "V5"
#> 
```
