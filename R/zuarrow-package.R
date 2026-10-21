#' @keywords internal
"_PACKAGE"

## usethis namespace: start
#' @useDynLib zuarrow, .registration = TRUE
## usethis namespace: end

# zukomp's namespace must be loaded before its C table is resolved
# (zukomp-r.h); importing one function is what loads it.
#' @importFrom zukomp komp_codec_available

NULL
