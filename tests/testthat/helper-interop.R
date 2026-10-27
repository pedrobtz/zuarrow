# Oracle 3 (design section 9) over every built-in type: each case builds
# one array with nanoarrow, through its builder where it has one and from
# raw buffers where it does not. `arrow` names the arrow_types() entry it
# covers. `zuarrow` builds the same values with zuarrow's internal
# constructor, for the types arrow_array() does not write (design section
# 2: views, run-end encoding, unions; also half floats, intervals and
# dictionaries of other values); otherwise arrow_array() builds them from
# the R values zuarrow reads. `r_form` is FALSE for the types with no R
# form, intervals and unions.
interop_cases <- function() {
  na <- asNamespace("nanoarrow")
  build <- function(values, schema) {
    na$as_nanoarrow_array(values, schema = schema)
  }
  na_raw <- function(
    schema,
    length,
    buffers,
    null_count = 0,
    children = NULL,
    dictionary = NULL
  ) {
    args <- list(length = length, null_count = null_count, buffers = buffers)
    args$children <- children
    args$dictionary <- dictionary
    na$nanoarrow_array_modify(na$nanoarrow_array_init(schema), args)
  }
  i32 <- function(x) writeBin(as.integer(x), raw(), endian = "little")
  i64 <- function(x) le_int(x, 8L)
  # A string or binary view of at most 12 bytes, inlined.
  view <- function(x) c(i32(length(x)), x, raw(12L - length(x)))
  case <- function(arrow, nanoarrow, zuarrow = NULL, r_form = TRUE) {
    list(
      arrow = arrow,
      nanoarrow = nanoarrow,
      zuarrow = zuarrow,
      r_form = r_form
    )
  }
  valid13 <- as.raw(0x05) # rows 1 and 3 valid, row 2 null
  secs <- as.difftime(c(1, NA, 3), units = "secs")
  ts <- as.POSIXct(c(0, NA, 1e9), tz = "UTC")
  dec <- c(1.25, NA, -3)
  items <- function() build(1:3, na$na_int32())
  list_view <- function(format, offsets) {
    list(
      nanoarrow = function() {
        schema <- if (format == "+vl") {
          na$na_list_view(na$na_int32())
        } else {
          na$na_large_list_view(na$na_int32())
        }
        na_raw(
          schema,
          3,
          list(valid13, offsets(c(0, 2, 2)), offsets(c(2, 0, 1))),
          1,
          list(items())
        )
      },
      zuarrow = function() {
        test_array(
          test_schema(zspec(format, children = list(zspec("i", "")))),
          3,
          list(valid13, offsets(c(0, 2, 2)), offsets(c(2, 0, 1))),
          null_count = 1,
          children = list(test_array_spec(3, list(NULL, i32(1:3))))
        )
      }
    )
  }
  views <- function(format, schema) {
    bytes <- list(charToRaw("a"), raw(), charToRaw("twelve bytes"))
    list(
      nanoarrow = function() {
        values <- if (format == "vu") {
          c("a", NA, "twelve bytes")
        } else {
          list(charToRaw("a"), NULL, charToRaw("twelve bytes"))
        }
        build(values, schema)
      },
      zuarrow = function() {
        test_array(
          format,
          3,
          list(valid13, unlist(lapply(bytes, view))),
          null_count = 1
        )
      }
    )
  }
  intervals <- function(format, schema, bytes) {
    list(
      nanoarrow = function() na_raw(schema, 2, list(NULL, bytes)),
      zuarrow = function() test_array(format, 2, list(NULL, bytes))
    )
  }
  unions <- function(dense) {
    format <- if (dense) "+ud:0,1" else "+us:0,1"
    ids <- as.raw(c(0, 1, 0))
    a <- if (dense) c(1L, 3L) else c(1L, 0L, 3L)
    b <- if (dense) "x" else c("", "x", "")
    buffers <- if (dense) list(ids, i32(c(0, 0, 1))) else list(ids)
    list(
      nanoarrow = function() {
        children <- list(
          a = build(a, na$na_int32()),
          b = build(b, na$na_string())
        )
        schema <- if (dense) na$na_dense_union else na$na_sparse_union
        na_raw(
          schema(list(a = na$na_int32(), b = na$na_string())),
          3,
          buffers,
          0,
          children
        )
      },
      zuarrow = function() {
        offsets <- c(0, cumsum(nchar(b)))
        test_array(
          test_schema(zspec(
            format,
            children = list(zspec("i", "a"), zspec("u", "b")),
            flags = 0L
          )),
          3,
          buffers,
          children = list(
            test_array_spec(length(a), list(NULL, i32(a))),
            test_array_spec(
              length(b),
              list(NULL, i32(offsets), charToRaw(paste(b, collapse = "")))
            )
          )
        )
      }
    )
  }
  lv <- list_view("+vl", i32)
  llv <- list_view("+vL", i64)
  vu <- views("vu", na$na_string_view())
  vz <- views("vz", na$na_binary_view())
  ud <- unions(TRUE)
  us <- unions(FALSE)
  im <- intervals("tiM", na$na_interval_months(), i32(c(14, -1)))
  idt <- intervals("tiD", na$na_interval_day_time(), i32(c(1, 500, -2, 0)))
  imdn <- intervals(
    "tin",
    na$na_interval_month_day_nano(),
    c(i32(c(1, 2)), i64(3), i32(c(0, -1)), i64(0))
  )
  list(
    case("null", function() build(c(NA, NA, NA), na$na_na())),
    case("bool", function() build(c(TRUE, NA, FALSE), na$na_bool())),
    case("int8", function() build(c(1L, NA, -3L), na$na_int8())),
    case("int16", function() build(c(1L, NA, -3L), na$na_int16())),
    case("uint8", function() build(c(1L, NA, 3L), na$na_uint8())),
    case("uint16", function() build(c(1L, NA, 3L), na$na_uint16())),
    case("int32", function() build(c(1L, NA, -3L), na$na_int32())),
    case("uint32", function() build(c(1, NA, 3), na$na_uint32())),
    case("int64", function() build(c(1, NA, -3), na$na_int64())),
    case("uint64", function() build(c(1, NA, 3), na$na_uint64())),
    case(
      "half_float",
      function() build(c(1.5, NA, -2), na$na_half_float()),
      function() {
        test_array(
          "e",
          3,
          list(valid13, le_int(c(0x3e00, 0, 0xc000), 2L)),
          null_count = 1
        )
      }
    ),
    case("float", function() build(c(1.5, NA, -2), na$na_float())),
    case("double", function() build(c(1.5, NA, -2), na$na_double())),
    case("utf8", function() build(c("a", NA, "\u00e9"), na$na_string())),
    case(
      "large_utf8",
      function() build(c("a", NA, "\u00e9"), na$na_large_string())
    ),
    case("utf8_view", vu$nanoarrow, vu$zuarrow),
    case(
      "binary",
      function() build(list(as.raw(1:2), NULL, raw()), na$na_binary())
    ),
    case(
      "large_binary",
      function() build(list(as.raw(1:2), NULL, raw()), na$na_large_binary())
    ),
    case("binary_view", vz$nanoarrow, vz$zuarrow),
    case(
      "fixed_size_binary",
      function() {
        build(list(as.raw(1:2), NULL, as.raw(3:4)), na$na_fixed_size_binary(2))
      }
    ),
    case(
      "date32",
      function() {
        build(as.Date(c("2020-01-01", NA, "1960-05-06")), na$na_date32())
      }
    ),
    case(
      "date64",
      function() {
        build(as.Date(c("2020-01-01", NA, "1960-05-06")), na$na_date64())
      }
    ),
    case("timestamp[s]", function() build(ts, na$na_timestamp("s", "UTC"))),
    case("timestamp[ms]", function() build(ts, na$na_timestamp("ms", ""))),
    case("timestamp[us]", function() build(ts, na$na_timestamp("us", "UTC"))),
    case("timestamp[ns]", function() build(ts, na$na_timestamp("ns", "UTC"))),
    case("time32", function() build(secs, na$na_time32("s"))),
    case("time32", function() build(secs, na$na_time32("ms"))),
    case("time64", function() build(secs, na$na_time64("us"))),
    case("time64", function() build(secs, na$na_time64("ns"))),
    case("duration", function() build(secs, na$na_duration("s"))),
    case("duration", function() build(secs, na$na_duration("ms"))),
    case("duration", function() build(secs, na$na_duration("us"))),
    case("duration", function() build(secs, na$na_duration("ns"))),
    case("decimal32", function() build(dec, na$na_decimal32(5, 2))),
    case("decimal64", function() build(dec, na$na_decimal64(5, 2))),
    case("decimal128", function() build(dec, na$na_decimal128(5, 2))),
    case("decimal256", function() build(dec, na$na_decimal256(5, 2))),
    case("interval", im$nanoarrow, im$zuarrow, r_form = FALSE),
    case("interval", idt$nanoarrow, idt$zuarrow, r_form = FALSE),
    case("interval", imdn$nanoarrow, imdn$zuarrow, r_form = FALSE),
    case("dense_union", ud$nanoarrow, ud$zuarrow, r_form = FALSE),
    case("sparse_union", us$nanoarrow, us$zuarrow, r_form = FALSE),
    case(
      "struct",
      function() {
        build(
          data.frame(a = 1:3, b = c("x", NA, "z")),
          na$na_struct(list(a = na$na_int32(), b = na$na_string()))
        )
      }
    ),
    case(
      "list",
      function() build(list(1:2, NULL, 3L), na$na_list(na$na_int32()))
    ),
    case(
      "large_list",
      function() build(list(1:2, NULL, 3L), na$na_large_list(na$na_int32()))
    ),
    case("list_view", lv$nanoarrow, lv$zuarrow),
    case("large_list_view", llv$nanoarrow, llv$zuarrow),
    case(
      "fixed_size_list",
      function() {
        build(list(1:2, NULL, 3:4), na$na_fixed_size_list(na$na_int32(), 2))
      }
    ),
    case(
      "map",
      function() {
        build(
          list(data.frame(key = c("a", "b"), value = c(1L, NA)), NULL),
          na$na_map(na$na_string(nullable = FALSE), na$na_int32())
        )
      }
    ),
    case(
      "dictionary of strings",
      function() {
        build(
          factor(c("b", NA, "a")),
          na$na_dictionary(na$na_string(), na$na_int32())
        )
      }
    ),
    case(
      "dictionary of other values",
      function() {
        na_raw(
          na$na_dictionary(na$na_double(), na$na_int32()),
          3,
          list(valid13, i32(c(1, 0, 0))),
          1,
          dictionary = build(c(0.5, 9), na$na_double())
        )
      },
      function() {
        schema <- test_schema(list(
          format = "i",
          name = "",
          flags = 2L,
          metadata = NULL,
          children = list(),
          dictionary = zspec("g")
        ))
        test_array(
          schema,
          3,
          list(valid13, i32(c(1, 0, 0))),
          null_count = 1,
          dictionary = test_array_spec(
            2,
            list(NULL, writeBin(c(0.5, 9), raw(), endian = "little"))
          )
        )
      }
    ),
    case(
      "run_end_encoded",
      function() {
        schema <- test_schema(zspec(
          "+r",
          children = list(
            zspec("i", "run_ends", flags = 0L),
            zspec("g", "values")
          )
        ))
        na_raw(
          schema,
          3,
          list(),
          0,
          list(
            run_ends = build(c(2L, 3L), na$na_int32(nullable = FALSE)),
            values = build(c(1.5, NA), na$na_double())
          )
        )
      },
      function() {
        schema <- test_schema(zspec(
          "+r",
          children = list(
            zspec("i", "run_ends", flags = 0L),
            zspec("g", "values")
          )
        ))
        test_array(
          schema,
          3,
          list(),
          children = list(
            test_array_spec(2, list(NULL, i32(c(2, 3)))),
            test_array_spec(
              2,
              list(as.raw(0x01), writeBin(c(1.5, 0), raw(), endian = "little")),
              null_count = 1
            )
          )
        )
      }
    ),
    case(
      "arrow.bool8 extension",
      function() {
        na_raw(
          na$na_extension(na$na_int8(), "arrow.bool8"),
          3,
          list(valid13, as.raw(c(1, 0, 0))),
          1
        )
      }
    )
  )
}
