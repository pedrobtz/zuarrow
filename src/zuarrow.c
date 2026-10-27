#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>

#include "zar.h"

SEXP zar_c_handle_status(SEXP x);
SEXP zar_c_schema_copy(SEXP x);
SEXP zar_c_schema_format(SEXP x, SEXP recursive);
SEXP zar_c_schema_from_spec(SEXP spec);
SEXP zar_c_schema_to_spec(SEXP x);
SEXP zar_c_schema_metadata(SEXP x);
SEXP zar_c_schema_with_metadata(SEXP x, SEXP metadata);
SEXP zar_c_nanoarrow_version(void);
SEXP zar_c_array_validate(SEXP x, SEXP level);
SEXP zar_c_stream_validate(SEXP x, SEXP level);
SEXP zar_c_schema_equal(SEXP x, SEXP y, SEXP metadata);
SEXP zar_c_array_equal(SEXP x, SEXP y, SEXP metadata);
SEXP zar_c_stream_equal(SEXP x, SEXP y, SEXP metadata);
SEXP zar_c_array_from_buffers(SEXP schema, SEXP spec);
SEXP zar_c_stream_from_arrays(SEXP schema, SEXP arrays);
SEXP zar_c_array_info(SEXP x);
SEXP zar_c_stream_next(SEXP x);
SEXP zar_c_array_child(SEXP x, SEXP k);
SEXP zar_c_array_nulls(SEXP x);
SEXP zar_c_array_borrow(SEXP x);
SEXP zar_c_reader_open(SEXP source, SEXP limits);
SEXP zar_c_reader_select(SEXP stream, SEXP columns);
SEXP zar_c_write(SEXP arrays, SEXP schema, SEXP opts);
SEXP zar_c_to_r(SEXP arrays, SEXP schema, SEXP opts);
SEXP zar_c_from_r(SEXP x, SEXP schema, SEXP start, SEXP n);
SEXP zar_c_utf8_over(SEXP x, SEXP limit);

#define ZAR_CALL(name, n) {#name, (DL_FUNC)&name, n}

static const R_CallMethodDef zar_call_methods[] = {
    ZAR_CALL(zar_c_handle_status, 1),
    ZAR_CALL(zar_c_schema_copy, 1),
    ZAR_CALL(zar_c_schema_format, 2),
    ZAR_CALL(zar_c_schema_from_spec, 1),
    ZAR_CALL(zar_c_schema_to_spec, 1),
    ZAR_CALL(zar_c_schema_metadata, 1),
    ZAR_CALL(zar_c_schema_with_metadata, 2),
    ZAR_CALL(zar_c_nanoarrow_version, 0),
    ZAR_CALL(zar_c_array_validate, 2),
    ZAR_CALL(zar_c_stream_validate, 2),
    ZAR_CALL(zar_c_schema_equal, 3),
    ZAR_CALL(zar_c_array_equal, 3),
    ZAR_CALL(zar_c_stream_equal, 3),
    ZAR_CALL(zar_c_array_from_buffers, 2),
    ZAR_CALL(zar_c_stream_from_arrays, 2),
    ZAR_CALL(zar_c_array_info, 1),
    ZAR_CALL(zar_c_stream_next, 1),
    ZAR_CALL(zar_c_array_child, 2),
    ZAR_CALL(zar_c_array_nulls, 1),
    ZAR_CALL(zar_c_array_borrow, 1),
    ZAR_CALL(zar_c_reader_open, 2),
    ZAR_CALL(zar_c_reader_select, 2),
    ZAR_CALL(zar_c_write, 3),
    ZAR_CALL(zar_c_to_r, 3),
    ZAR_CALL(zar_c_deferred_info, 1),
    ZAR_CALL(zar_c_from_r, 4),
    ZAR_CALL(zar_c_utf8_over, 2),
    {NULL, NULL, 0}};

void attribute_visible R_init_zuarrow(DllInfo *dll) {
  R_registerRoutines(dll, NULL, zar_call_methods, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
  R_forceSymbols(dll, TRUE);
  zar_altrep_init(dll);
}
