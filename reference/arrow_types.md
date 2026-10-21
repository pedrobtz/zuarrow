# The built-in type table

Lists every Arrow type zuarrow converts without a registration: its
format string, its R form, whether that form is exact, the R form
`lossy = "allow"` gives otherwise, and the package that reads it
exactly.

## Usage

``` r
arrow_types()
```

## Value

A data frame with columns `arrow`, `format`, `r`, `exact`, `lossy_r` and
`exact_with`.

## Examples

``` r
arrow_types()
#>                                           arrow             format
#> 1                                          null                  n
#> 2                                          bool                  b
#> 3                    int8, int16, uint8, uint16         c, s, C, S
#> 4                                         int32                  i
#> 5                                        uint32                  I
#> 6                     half_float, float, double            e, f, g
#> 7                                         int64                  l
#> 8                                        uint64                  L
#> 9                   utf8, large_utf8, utf8_view           u, U, vu
#> 10            binary, large_binary, binary_view           z, Z, vz
#> 11                            fixed_size_binary                w:n
#> 12                                       date32                tdD
#> 13                                       date64                tdm
#> 14                  timestamp[s], timestamp[ms]         tss:, tsm:
#> 15                 timestamp[us], timestamp[ns]         tsu:, tsn:
#> 16                               time32, time64 tts, ttm, ttu, ttn
#> 17                                     duration tDs, tDm, tDu, tDn
#> 18 decimal32, decimal64, decimal128, decimal256              d:p,s
#> 19                                     interval      tiM, tiD, tin
#> 20                    dense_union, sparse_union         +ud:, +us:
#> 21                                       struct                 +s
#>                           r                     exact
#> 1              logical (NA)                       yes
#> 2                   logical                       yes
#> 3                   integer                       yes
#> 4                   integer unless a value is INT_MIN
#> 5                    double                       yes
#> 6                    double                       yes
#> 7                    double            within +/-2^53
#> 8                    double                up to 2^53
#> 9                 character  unless a value holds NUL
#> 10              list of raw                       yes
#> 11 list of raw, arrow_width                       yes
#> 12                     Date                       yes
#> 13                                                 no
#> 14                  POSIXct      within +/-2^53 units
#> 15                                                 no
#> 16                                                 no
#> 17                                                 no
#> 18                                                 no
#> 19                                                 no
#> 20                                                 no
#> 21               data.frame                       yes
#>                            lossy_r exact_with
#> 1                                            
#> 2                                            
#> 3                                            
#> 4                     integer (NA)           
#> 5                                            
#> 6                                            
#> 7  double, or integer64 with bit64      zuint
#> 8                           double      zuint
#> 9            character, cut at NUL           
#> 10                                           
#> 11                                           
#> 12                                           
#> 13                         POSIXct    zutempo
#> 14                         POSIXct    zutempo
#> 15                         POSIXct    zutempo
#> 16                        difftime    zutempo
#> 17                        difftime    zutempo
#> 18                          double    decimal
#> 19                            none    zutempo
#> 20                            none           
#> 21                                           
```
