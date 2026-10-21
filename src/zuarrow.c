#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>

static const R_CallMethodDef zar_call_methods[] = {
  {NULL, NULL, 0}
};

void attribute_visible R_init_zuarrow(DllInfo *dll) {
  R_registerRoutines(dll, NULL, zar_call_methods, NULL, NULL);
  R_useDynamicSymbols(dll, FALSE);
  R_forceSymbols(dll, TRUE);
}
