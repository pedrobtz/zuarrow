# Taking IPC bytes apart and building messages by hand, so a test can make
# input that breaks one rule of design section 6.7 and no other. Positions
# are 0-based byte offsets, as in the format.

le_read <- function(bytes, pos, n) {
  sum(as.integer(bytes[pos + seq_len(n)]) * 256^(seq_len(n) - 1L))
}

# The message starting at `pos`: its start, the bytes of its prefix and
# FlatBuffer (the footer's metaDataLength), its body length and its header
# type (1 schema, 2 dictionary batch, 3 record batch). NULL at the
# end-of-stream marker.
ipc_message_at <- function(bytes, pos) {
  stopifnot(le_read(bytes, pos, 4) == 2^32 - 1)
  len <- le_read(bytes, pos + 4, 4)
  if (len == 0) {
    return(NULL)
  }
  fb <- pos + 8
  table <- fb + le_read(bytes, fb, 4)
  soffset <- le_read(bytes, table, 4)
  if (soffset >= 2^31) {
    soffset <- soffset - 2^32
  }
  vtable <- table - soffset
  slots <- (le_read(bytes, vtable, 2) - 4) / 2
  field <- function(id, n) {
    if (id >= slots) {
      return(0)
    }
    at <- le_read(bytes, vtable + 4 + 2 * id, 2)
    if (at == 0) 0 else le_read(bytes, table + at, n)
  }
  list(
    start = pos,
    meta = 8 + len,
    body = field(3, 8),
    type = field(1, 1)
  )
}

# Every message from `pos` (8 for a file) to the end-of-stream marker.
ipc_messages <- function(bytes, pos = 0) {
  out <- list()
  repeat {
    m <- ipc_message_at(bytes, pos)
    if (is.null(m)) {
      break
    }
    out[[length(out) + 1L]] <- m
    pos <- m$start + m$meta + m$body
  }
  out
}

# The bytes of message `m`, with its body.
ipc_message_bytes <- function(bytes, m) {
  bytes[m$start + seq_len(m$meta + m$body)]
}

# A stream of one factor column: schema, dictionary, record batch.
factor_stream <- function(levels, values = levels) {
  arrow_write(
    data.frame(f = factor(values, levels = levels)),
    NULL,
    format = "stream"
  )
}

ipc_eos <- function() as.raw(c(255, 255, 255, 255, 0, 0, 0, 0))

# The position of a file footer's Block for message `m`: offset, then
# metaDataLength, as written.
ipc_block_at <- function(bytes, m) {
  at <- bytes_at(bytes, c(le_int(m$start, 8L), le_int(m$meta, 4L)))
  stopifnot(length(at) == 1L)
  at[[1]] - 1L
}

# `bytes` with the footer Block of message `to` replaced by that of `from`.
ipc_swap_block <- function(bytes, from, to) {
  src <- ipc_block_at(bytes, from)
  dst <- ipc_block_at(bytes, to)
  bytes[dst + 1:24] <- bytes[src + 1:24]
  bytes
}

# ---- a small FlatBuffers writer ------------------------------------------

fb_new <- function() {
  b <- new.env()
  b$buf <- raw(4) # the root offset, set by fb_finish()
  b
}

fb_align <- function(b, a, extra = 0) {
  pad <- (a - (length(b$buf) + extra) %% a) %% a
  b$buf <- c(b$buf, raw(pad))
}

# Writes a vtable and its table. `fields` is a list of list(id, bytes,
# align); `bytes = NULL` is an offset to a later object, returned by id.
fb_table <- function(b, fields) {
  slots <- max(vapply(fields, function(f) f$id, 0)) + 1
  fb_align(b, 2)
  vtable <- length(b$buf)
  b$buf <- c(b$buf, raw(4 + 2 * slots))
  fb_align(b, 8)
  table <- length(b$buf)
  b$buf <- c(b$buf, le_int(table - vtable, 4L))
  at <- integer(slots)
  refs <- list()
  for (f in fields) {
    fb_align(b, f$align)
    pos <- length(b$buf)
    at[f$id + 1] <- pos - table
    if (is.null(f$bytes)) {
      refs[[as.character(f$id)]] <- pos
      b$buf <- c(b$buf, raw(4))
    } else {
      b$buf <- c(b$buf, f$bytes)
    }
  }
  size <- length(b$buf) - table
  b$buf[vtable + seq_len(4 + 2 * slots)] <- c(
    le_int(4 + 2 * slots, 2L),
    le_int(size, 2L),
    le_int(at, 2L)
  )
  list(pos = table, refs = refs)
}

fb_set_ref <- function(b, ref, target) {
  b$buf[ref + 1:4] <- le_int(target - ref, 4L)
}

# A vector of 16-byte structs (two int64 each).
fb_struct_vector <- function(b, pairs) {
  fb_align(b, 8, extra = 4)
  pos <- length(b$buf)
  b$buf <- c(b$buf, le_int(length(pairs), 4L))
  for (p in pairs) {
    b$buf <- c(b$buf, le_int(p, 8L))
  }
  pos
}

fb_field <- function(id, value, size) {
  list(id = id, bytes = le_int(value, size), align = size)
}

# A DictionaryBatch message with its framing, followed by `body`. `nodes`
# and `buffers` are lists of c(length, null_count) and c(offset, length);
# with `data = FALSE` the batch has no RecordBatch.
ipc_dictionary_message <- function(
  id,
  length,
  nodes,
  buffers,
  body,
  is_delta = FALSE,
  data = TRUE
) {
  body <- c(body, raw((8 - length(body) %% 8) %% 8))
  b <- fb_new()
  message <- fb_table(
    b,
    list(
      fb_field(0, 4, 2), # version V5
      fb_field(1, 2, 1), # header type DictionaryBatch
      list(id = 2, bytes = NULL, align = 4),
      fb_field(3, length(body), 8)
    )
  )
  b$buf[1:4] <- le_int(message$pos, 4L)
  fields <- list(fb_field(0, id, 8), fb_field(2, as.integer(is_delta), 1))
  if (data) {
    fields <- c(fields, list(list(id = 1, bytes = NULL, align = 4)))
  }
  dictionary <- fb_table(b, fields)
  fb_set_ref(b, message$refs[["2"]], dictionary$pos)
  if (data) {
    batch <- fb_table(
      b,
      list(
        fb_field(0, length, 8),
        list(id = 1, bytes = NULL, align = 4),
        list(id = 2, bytes = NULL, align = 4)
      )
    )
    fb_set_ref(b, dictionary$refs[["1"]], batch$pos)
    fb_set_ref(b, batch$refs[["1"]], fb_struct_vector(b, nodes))
    fb_set_ref(b, batch$refs[["2"]], fb_struct_vector(b, buffers))
  }
  fb_align(b, 8)
  c(
    as.raw(c(255, 255, 255, 255)),
    le_int(length(b$buf), 4L),
    b$buf,
    body
  )
}

# A dictionary batch of utf8 values, as ipc_dictionary_message() takes.
ipc_utf8_dictionary <- function(id, values, is_delta = FALSE) {
  bytes <- lapply(values, charToRaw)
  offsets <- c(0, cumsum(lengths(bytes)))
  offsets_raw <- le_int(offsets, 4L)
  offsets_raw <- c(offsets_raw, raw((8 - length(offsets_raw) %% 8) %% 8))
  data <- unlist(bytes)
  ipc_dictionary_message(
    id,
    length(values),
    nodes = list(c(length(values), 0)),
    buffers = list(
      c(0, 0),
      c(0, length(values) * 4 + 4),
      c(length(offsets_raw), length(data))
    ),
    body = c(offsets_raw, data),
    is_delta = is_delta
  )
}
