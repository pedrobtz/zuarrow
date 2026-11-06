#' @keywords internal
"_PACKAGE"

## usethis namespace: start
#' @useDynLib zuarrow, .registration = TRUE
## usethis namespace: end

# zukomp's namespace must be loaded before its C table is resolved
# (zukomp-r.h); importing one function is what loads it.
#' @importFrom zukomp komp_codec_available

NULL

#' Package information
#'
#' Reports the versions zuarrow is built from: its own, the vendored
#' 'nanoarrow' C library's, and the IPC metadata version it writes.
#'
#' @returns A named list with `zuarrow`, `nanoarrow` and `ipc_metadata`.
#' @export
#' @examples
#' zuarrow_info()
zuarrow_info <- function() {
  list(
    zuarrow = as.character(utils::packageVersion("zuarrow")),
    nanoarrow = .Call(zar_c_nanoarrow_version),
    ipc_metadata = "V5"
  )
}
