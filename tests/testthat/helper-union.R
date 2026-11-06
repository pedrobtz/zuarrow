# Union columns read through a registered extension handler (#171).

# The schema spec of a dense or sparse union with extension `name` over
# children a (int32) and b (utf8), type ids 3 and 7.
union_ext_spec <- function(dense, name = "test.union", field = "") {
  spec <- zspec(
    if (dense) "+ud:3,7" else "+us:3,7",
    field,
    children = list(zspec("i", "a"), zspec("u", "b"))
  )
  spec$metadata <- list(
    "ARROW:extension:name" = charToRaw(name),
    "ARROW:extension:metadata" = raw()
  )
  spec
}

# The array spec of that union holding the rows 10, "x", 20, "y".
union_ext_array_spec <- function(dense, offset = 0, length = 4 - offset) {
  ids <- as.raw(c(3, 7, 3, 7))
  children <- if (dense) {
    list(
      test_array_spec(2, list(NULL, le_int(c(10, 20), 4L))),
      test_array_spec(2, c(list(NULL), test_string_buffers(c("x", "y"))))
    )
  } else {
    list(
      test_array_spec(4, list(NULL, le_int(c(10, 0, 20, 0), 4L))),
      test_array_spec(
        4,
        c(list(NULL), test_string_buffers(c("", "x", "", "y")))
      )
    )
  }
  buffers <- if (dense) list(ids, le_int(c(0, 0, 1, 1), 4L)) else list(ids)
  test_array_spec(length, buffers, offset = offset, children = children)
}

union_ext_array <- function(dense, offset = 0, length = 4 - offset) {
  spec <- union_ext_array_spec(dense, offset, length)
  test_array(
    test_schema(union_ext_spec(dense)),
    length,
    spec$buffers,
    offset = offset,
    children = spec$children
  )
}

# Each row of a union array handle as text, read from its buffers as a
# handler written in C reads them: the type id picks the child, and a
# dense union's offset, or else the row, picks the child's element.
union_rows_text <- function(array) {
  s <- test_array_to_spec(array)
  dense <- length(s$buffers) == 2L
  ids <- as.integer(s$buffers[[1]])
  offsets <- if (dense) readBin(s$buffers[[2]], "integer", length(ids), 4L)
  rows <- s$offset + seq_len(s$length)
  vapply(
    rows,
    function(i) {
      j <- if (dense) offsets[[i]] + 1L else i
      if (ids[[i]] == 3L) {
        a <- s$children[[1]]
        n <- length(a$buffers[[2]]) %/% 4L
        return(as.character(readBin(a$buffers[[2]], "integer", n, 4L)[[j]]))
      }
      b <- s$children[[2]]
      ends <- readBin(b$buffers[[2]], "integer", b$length + 1L, 4L)
      rawToChar(b$buffers[[3]][seq.int(ends[[j]] + 1L, ends[[j + 1L]])])
    },
    ""
  )
}

# A geoarrow.geometry handler for data/geometry-union.arrows, which
# tools/make-union-fixture.py writes: each row as WKT, read from the dense
# union's type ids, offsets and children.
geometry_wkt <- function(array, schema) {
  s <- test_array_to_spec(array)
  ids <- as.integer(s$buffers[[1]])
  offsets <- readBin(s$buffers[[2]], "integer", length(ids), 4L)
  coord <- function(spec, j) {
    n <- length(spec$buffers[[2]]) %/% 8L
    readBin(spec$buffers[[2]], "double", n, 8L)[[j]]
  }
  coords <- function(struct, j) {
    paste(vapply(struct$children, coord, 0, j = j), collapse = " ")
  }
  point <- s$children[[1]]
  line <- s$children[[2]]
  point_z <- s$children[[3]]
  rows <- s$offset + seq_len(s$length)
  vapply(
    rows,
    function(i) {
      j <- offsets[[i]] + 1L
      switch(
        as.character(ids[[i]]),
        "1" = sprintf("POINT (%s)", coords(point, j)),
        "2" = {
          ends <- readBin(line$buffers[[2]], "integer", line$length + 1L, 4L)
          vertices <- seq.int(ends[[j]] + 1L, ends[[j + 1L]])
          text <- vapply(vertices, coords, "", struct = line$children[[1]])
          sprintf("LINESTRING (%s)", paste(text, collapse = ", "))
        },
        "11" = sprintf("POINT Z (%s)", coords(point_z, j))
      )
    },
    ""
  )
}
