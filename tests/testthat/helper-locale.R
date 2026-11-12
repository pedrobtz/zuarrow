# Locales and the export routes of a string, for test-from-r-exact.R.

# Sets LC_CTYPE for the rest of the calling test, or skips it.
local_ctype <- function(locales, frame = parent.frame()) {
  for (locale in locales) {
    old <- Sys.getlocale("LC_CTYPE")
    set <- suppressWarnings(Sys.setlocale("LC_CTYPE", locale))
    if (nzchar(set)) {
      withr::defer(Sys.setlocale("LC_CTYPE", old), envir = frame)
      return(invisible(set))
    }
  }
  testthat::skip(paste("none of these locales can be set:", toString(locales)))
}

# The ways a native string reaches Arrow text: a value, a factor level, a
# column name, a metadata key and value, an extension name.
export_routes <- function(s) {
  df <- data.frame(x = 1L)
  names(df) <- s
  field <- structure(1L, arrow_field_metadata = stats::setNames("v", s))
  value <- structure(1L, arrow_field_metadata = c(k = s))
  schema <- arrow_schema("i")
  list(
    value = function() arrow_array(s),
    ipc = function() arrow_write(data.frame(x = s), NULL),
    level = function() arrow_array(factor(s)),
    name = function() arrow_array(df),
    key = function() arrow_array(field),
    metadata = function() arrow_metadata(schema) <- c(k = s),
    field = function() arrow_array(value),
    extension = function() arrow_array(structure(1L, arrow_extension = s))
  )
}
