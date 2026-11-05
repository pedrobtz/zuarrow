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

A data frame of character columns: `arrow`, `format`, `r`, `exact`,
`lossy_r` and `exact_with`. `exact` describes when the R form is exact,
as text such as `"yes"`, `"no"` or `"within +/-2^53"`, not as a logical.

## Examples

``` r
arrow_types()
#>                                           arrow                   format
#> 1                                          null                        n
#> 2                                          bool                        b
#> 3                    int8, int16, uint8, uint16               c, s, C, S
#> 4                                         int32                        i
#> 5                                        uint32                        I
#> 6                     half_float, float, double                  e, f, g
#> 7                                         int64                        l
#> 8                                        uint64                        L
#> 9                   utf8, large_utf8, utf8_view                 u, U, vu
#> 10            binary, large_binary, binary_view                 z, Z, vz
#> 11                            fixed_size_binary                      w:n
#> 12                                       date32                      tdD
#> 13                                       date64                      tdm
#> 14                                 timestamp[s]                     tss:
#> 15                 timestamp[ms], timestamp[us]               tsm:, tsu:
#> 16                                timestamp[ns]                     tsn:
#> 17                               time32, time64       tts, ttm, ttu, ttn
#> 18                                     duration       tDs, tDm, tDu, tDn
#> 19 decimal32, decimal64, decimal128, decimal256                    d:p,s
#> 20                                     interval            tiM, tiD, tin
#> 21                    dense_union, sparse_union               +ud:, +us:
#> 22                                       struct                       +s
#> 23 list, large_list, list_view, large_list_view         +l, +L, +vl, +vL
#> 24                              fixed_size_list                     +w:n
#> 25                                          map                       +m
#> 26                        dictionary of strings             index + utf8
#> 27                   dictionary of other values           index + values
#> 28                              run_end_encoded                       +r
#> 29                        arrow.bool8 extension c + ARROW:extension:name
#>                                          r
#> 1                             logical (NA)
#> 2                                  logical
#> 3                                  integer
#> 4                                  integer
#> 5                                   double
#> 6                                   double
#> 7                                   double
#> 8                                   double
#> 9                                character
#> 10                             list of raw
#> 11                list of raw, arrow_width
#> 12                                    Date
#> 13                                        
#> 14                                 POSIXct
#> 15                                 POSIXct
#> 16                                        
#> 17                                        
#> 18                                        
#> 19                                        
#> 20                                        
#> 21                                        
#> 22                              data.frame
#> 23                             list column
#> 24 list column; matrix with arrow_matrix()
#> 25    list column of key/value data frames
#> 26                                  factor
#> 27                      the values' R form
#> 28                      the values' R form
#> 29                                 logical
#>                                     exact                         lossy_r
#> 1                                     yes                                
#> 2                                     yes                                
#> 3                                     yes                                
#> 4               unless a value is INT_MIN                    integer (NA)
#> 5                                     yes                                
#> 6                                     yes                                
#> 7                          within +/-2^53 double, or integer64 with bit64
#> 8                              up to 2^53                          double
#> 9                unless a value holds NUL           character, cut at NUL
#> 10                                    yes                                
#> 11                                    yes                                
#> 12                                    yes                                
#> 13                                     no                         POSIXct
#> 14                 within +/-2^53 seconds                         POSIXct
#> 15 when the double of seconds rounds back                         POSIXct
#> 16                                     no                         POSIXct
#> 17                                     no                        difftime
#> 18                                     no                        difftime
#> 19                                     no                          double
#> 20                                     no                            none
#> 21                                     no                            none
#> 22                                    yes                                
#> 23                                    yes                                
#> 24                                    yes                                
#> 25                                    yes                                
#> 26                                    yes                                
#> 27                          as the values                                
#> 28                          as the values                                
#> 29                                    yes                                
#>    exact_with
#> 1            
#> 2            
#> 3            
#> 4            
#> 5            
#> 6            
#> 7       zuint
#> 8       zuint
#> 9            
#> 10           
#> 11           
#> 12           
#> 13    zutempo
#> 14    zutempo
#> 15    zutempo
#> 16    zutempo
#> 17    zutempo
#> 18    zutempo
#> 19    decimal
#> 20    zutempo
#> 21           
#> 22           
#> 23           
#> 24           
#> 25           
#> 26           
#> 27           
#> 28           
#> 29           
```
