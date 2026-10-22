/* Deferred strings: an ALTREP character vector over Arrow string buffers.

   With copy = FALSE, arrow_to_r() returns string and large_string columns
   as this class instead of creating every R string at once. Each element's
   CHARSXP is made on first access and cached, so the cost moves from the
   conversion to the first use and is paid once per element. When every
   element has been made, the vector lets go of the Arrow batches.

   data1 is list(arrays, chunks): the array handles that own the buffers,
   which keeps them alive, and a raw vector of struct zar_deferred_chunk.
   arrays becomes NULL once every element is made.
   data2 is R_NilValue until the first access, then list(cache, made,
   count): the STRSXP of the elements made so far, a raw vector with one
   byte per element that says which, and how many as a double.

   The bytes were checked when the column was converted, so an element can
   no longer fail, except when someone has since released one of the array
   handles: that is a zuarrow_handle_error, not a read of freed memory.

   Serialization has no method, so R writes the plain character vector:
   reading it back does not need zuarrow. */
#include <string.h>

#include "zar.h"

#include <R_ext/Altrep.h>

static R_altrep_class_t zar_deferred_class;

static SEXP zar_arrays(SEXP x) { return VECTOR_ELT(R_altrep_data1(x), 0); }

static const struct zar_deferred_chunk *zar_chunks(SEXP x, int64_t *n) {
  SEXP raw = VECTOR_ELT(R_altrep_data1(x), 1);
  *n = (int64_t)(Rf_xlength(raw) / (R_xlen_t)sizeof(struct zar_deferred_chunk));
  return (const struct zar_deferred_chunk *)RAW(raw);
}

static R_xlen_t zar_deferred_length(SEXP x) {
  int64_t n;
  const struct zar_deferred_chunk *c = zar_chunks(x, &n);
  return n == 0 ? 0 : (R_xlen_t)(c[n - 1].begin + c[n - 1].length);
}

static int zar_complete(SEXP x) {
  SEXP state = R_altrep_data2(x);
  return state != R_NilValue &&
         REAL(VECTOR_ELT(state, 2))[0] == (double)zar_deferred_length(x);
}

/* Raises zuarrow_handle_error through R's zar_deferred_released(). An
   ALTREP method may call R; only the conversion kernels may not. */
static void zar_released(void) {
  SEXP ns = PROTECT(R_FindNamespace(Rf_mkString("zuarrow")));
  SEXP fn = PROTECT(Rf_findFun(Rf_install("zar_deferred_released"), ns));
  SEXP call = PROTECT(Rf_lang1(fn));
  Rf_eval(call, ns);
  UNPROTECT(3);
  Rf_error("the Arrow array behind a deferred character vector was released");
}

/* The CHARSXP of element i, made from the Arrow buffers. */
static SEXP zar_make_elt(SEXP x, R_xlen_t i) {
  int64_t n;
  const struct zar_deferred_chunk *chunks = zar_chunks(x, &n);
  int64_t lo = 0, hi = n - 1;
  while (lo < hi) {
    int64_t mid = lo + (hi - lo + 1) / 2;
    if (chunks[mid].begin <= (int64_t)i) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  const struct zar_deferred_chunk *c = &chunks[lo];

  SEXP handle = VECTOR_ELT(zar_arrays(x), (R_xlen_t)c->batch);
  struct ArrowArray *array = (struct ArrowArray *)R_ExternalPtrAddr(handle);
  if (array == NULL || array->release == NULL) zar_released();

  int64_t k = (int64_t)i - c->begin;
  if (c->validity != NULL && !ArrowBitGet(c->validity, c->validity_offset + k)) {
    return NA_STRING;
  }
  int64_t start, end;
  if (c->large) {
    const int64_t *o = (const int64_t *)c->offsets;
    memcpy(&start, o + k, sizeof(start));
    memcpy(&end, o + k + 1, sizeof(end));
  } else {
    const int32_t *o = (const int32_t *)c->offsets;
    int32_t s32, e32;
    memcpy(&s32, o + k, sizeof(s32));
    memcpy(&e32, o + k + 1, sizeof(e32));
    start = s32;
    end = e32;
  }
  int64_t len = end - start;
  if (len == 0) return R_BlankString;
  /* Cut at the first NUL, as the copying conversion does: only a lossy
     policy lets a string with one reach here. */
  const char *bytes = c->data + start;
  const char *nul = memchr(bytes, 0, (size_t)len);
  if (nul != NULL) len = nul - bytes;
  if (len == 0) return R_BlankString;
  return Rf_mkCharLenCE(bytes, (int)len, CE_UTF8);
}

/* The cache, allocated on first use. */
static SEXP zar_state(SEXP x) {
  SEXP state = R_altrep_data2(x);
  if (state != R_NilValue) return state;
  R_xlen_t n = zar_deferred_length(x);
  state = PROTECT(Rf_allocVector(VECSXP, 3));
  SET_VECTOR_ELT(state, 0, Rf_allocVector(STRSXP, n));
  SEXP made = Rf_allocVector(RAWSXP, n);
  SET_VECTOR_ELT(state, 1, made);
  if (n > 0) memset(RAW(made), 0, (size_t)n);
  SET_VECTOR_ELT(state, 2, Rf_ScalarReal(0));
  R_set_altrep_data2(x, state);
  UNPROTECT(1);
  return state;
}

/* Once every element is made the Arrow batches are no longer needed. */
static void zar_drop_arrays_if_complete(SEXP x) {
  if (zar_complete(x)) SET_VECTOR_ELT(R_altrep_data1(x), 0, R_NilValue);
}

static SEXP zar_deferred_elt(SEXP x, R_xlen_t i) {
  SEXP state = zar_state(x);
  SEXP cache = VECTOR_ELT(state, 0);
  Rbyte *made = RAW(VECTOR_ELT(state, 1));
  if (made[i]) return STRING_ELT(cache, i);
  SEXP elt = PROTECT(zar_make_elt(x, i));
  SET_STRING_ELT(cache, i, elt);
  made[i] = 1;
  REAL(VECTOR_ELT(state, 2))[0] += 1;
  zar_drop_arrays_if_complete(x);
  UNPROTECT(1);
  return elt;
}

static SEXP zar_materialize(SEXP x) {
  SEXP state = zar_state(x);
  if (!zar_complete(x)) {
    SEXP cache = VECTOR_ELT(state, 0);
    Rbyte *made = RAW(VECTOR_ELT(state, 1));
    R_xlen_t n = zar_deferred_length(x);
    for (R_xlen_t i = 0; i < n; i++) {
      if (made[i]) continue;
      SET_STRING_ELT(cache, i, zar_make_elt(x, i));
      made[i] = 1;
    }
    REAL(VECTOR_ELT(state, 2))[0] = (double)n;
    zar_drop_arrays_if_complete(x);
  }
  return VECTOR_ELT(state, 0);
}

static void *zar_deferred_dataptr(SEXP x, Rboolean writable) {
  (void)writable;
  return (void *)STRING_PTR_RO(zar_materialize(x));
}

static const void *zar_deferred_dataptr_or_null(SEXP x) {
  return zar_complete(x) ? (const void *)STRING_PTR_RO(VECTOR_ELT(R_altrep_data2(x), 0))
                         : NULL;
}

static void zar_deferred_set_elt(SEXP x, R_xlen_t i, SEXP v) {
  SET_STRING_ELT(zar_materialize(x), i, v);
}

static int zar_deferred_no_na(SEXP x) {
  int64_t n;
  const struct zar_deferred_chunk *chunks = zar_chunks(x, &n);
  for (int64_t k = 0; k < n; k++) {
    if (chunks[k].validity != NULL) return 0;
  }
  return 1;
}

static Rboolean zar_deferred_inspect(SEXP x, int pre, int deep, int pvec,
                                     void (*inspect_subtree)(SEXP, int, int, int)) {
  (void)pre;
  (void)deep;
  (void)pvec;
  (void)inspect_subtree;
  SEXP state = R_altrep_data2(x);
  double made = state == R_NilValue ? 0 : REAL(VECTOR_ELT(state, 2))[0];
  Rprintf("zuarrow deferred strings (len=%.0f, made=%.0f)\n",
          (double)zar_deferred_length(x), made);
  return TRUE;
}

void zar_altrep_init(DllInfo *dll) {
  zar_deferred_class = R_make_altstring_class("zar_deferred_strings", "zuarrow", dll);
  R_set_altrep_Length_method(zar_deferred_class, zar_deferred_length);
  R_set_altrep_Inspect_method(zar_deferred_class, zar_deferred_inspect);
  R_set_altvec_Dataptr_method(zar_deferred_class, zar_deferred_dataptr);
  R_set_altvec_Dataptr_or_null_method(zar_deferred_class, zar_deferred_dataptr_or_null);
  R_set_altstring_Elt_method(zar_deferred_class, zar_deferred_elt);
  R_set_altstring_Set_elt_method(zar_deferred_class, zar_deferred_set_elt);
  R_set_altstring_No_NA_method(zar_deferred_class, zar_deferred_no_na);
}

SEXP zar_deferred_strings(SEXP arrays, const struct zar_deferred_chunk *chunks,
                          int64_t n_chunks) {
  SEXP data1 = PROTECT(Rf_allocVector(VECSXP, 2));
  SET_VECTOR_ELT(data1, 0, arrays);
  SEXP raw = Rf_allocVector(RAWSXP, (R_xlen_t)n_chunks *
                                        (R_xlen_t)sizeof(struct zar_deferred_chunk));
  SET_VECTOR_ELT(data1, 1, raw);
  if (n_chunks > 0) {
    memcpy(RAW(raw), chunks, (size_t)n_chunks * sizeof(struct zar_deferred_chunk));
  }
  SEXP out = R_new_altrep(zar_deferred_class, data1, R_NilValue);
  UNPROTECT(1);
  return out;
}

SEXP zar_c_deferred_info(SEXP x) {
  if (!R_altrep_inherits(x, zar_deferred_class)) return R_NilValue;
  SEXP state = R_altrep_data2(x);
  double made = state == R_NilValue ? 0 : REAL(VECTOR_ELT(state, 2))[0];
  const char *names[] = {"made", "holds_arrays", ""};
  SEXP out = PROTECT(Rf_mkNamed(VECSXP, names));
  SET_VECTOR_ELT(out, 0, Rf_ScalarReal(made));
  SEXP holds = Rf_allocVector(LGLSXP, 1);
  LOGICAL(holds)[0] = VECTOR_ELT(R_altrep_data1(x), 0) != R_NilValue;
  SET_VECTOR_ELT(out, 1, holds);
  UNPROTECT(1);
  return out;
}
