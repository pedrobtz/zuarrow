# The R face of the archive consumer. Nothing here calls zuarrow: see
# NAMESPACE for why that is the point.

# A stream of two batches built with zuarrow's bundled nanoarrow builders:
# columns of the formats b, i, l, g, u, z, tdD and tsu:UTC.
build_stream <- function() .Call(C_build_stream)

# zuarrow_open_stream() on a path: list(stream, code, kind, message).
read_ipc <- function(path, columns = NULL, max_bytes = NULL) {
  if (!is.null(max_bytes)) {
    max_bytes <- as.double(max_bytes)
  }
  .Call(C_read_ipc, path.expand(path), columns, max_bytes)
}

# Every column of a stream as an R vector, converted in this package's C:
# l, tdD and tsu: as doubles of their integer values (days, microseconds).
stream_columns <- function(stream) .Call(C_stream_columns, stream)

# zuarrow_parse_int64() and zuarrow_parse_date(): code 0 (parsed), 1
# (EINVAL) or 2 (ERANGE), and the value.
parse_int64 <- function(x) .Call(C_parse, "int64", as.character(x))
parse_date <- function(x) .Call(C_parse, "date", as.character(x))

# c(header, archive): ZUARROW_ABI_VERSION as compiled and as linked.
abi <- function() .Call(C_abi)
