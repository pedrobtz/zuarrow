/* The exact text forms of design section 6.3, read back. A character
   column whose arrow_type attribute names a type with a text form is
   written as that type, and each value must parse exactly: digits for
   integers and durations, a decimal at most at its scale, ISO 8601 at most
   at the unit's precision for timestamps, date64 and times. Nothing is
   rounded; a value that does not parse is reported with its row. */
#include <string.h>

#include "zar.h"

static int zar_digit(char c) { return c >= '0' && c <= '9'; }

/* Strict: an optional sign, at least one digit, nothing after. */
int zar_parse_int64(const char *s, int64_t *out) {
  int neg = *s == '-';
  if (*s == '-' || *s == '+') s++;
  if (!zar_digit(*s)) return EINVAL;
  uint64_t v = 0;
  for (; zar_digit(*s); s++) {
    uint64_t d = (uint64_t)(*s - '0');
    if (v > (UINT64_MAX - d) / 10) return ERANGE;
    v = v * 10 + d;
  }
  if (*s != '\0') return EINVAL;
  if (neg) {
    if (v > (uint64_t)INT64_MAX + 1) return ERANGE;
    *out = v == (uint64_t)INT64_MAX + 1 ? INT64_MIN : -(int64_t)v;
  } else {
    if (v > (uint64_t)INT64_MAX) return ERANGE;
    *out = (int64_t)v;
  }
  return NANOARROW_OK;
}

int zar_parse_uint64(const char *s, uint64_t *out) {
  if (*s == '+') s++;
  if (!zar_digit(*s)) return EINVAL;
  uint64_t v = 0;
  for (; zar_digit(*s); s++) {
    uint64_t d = (uint64_t)(*s - '0');
    if (v > (UINT64_MAX - d) / 10) return ERANGE;
    v = v * 10 + d;
  }
  if (*s != '\0') return EINVAL;
  *out = v;
  return NANOARROW_OK;
}

/* "[-]digits[.digits]" with at most `scale` fraction digits and at most
   `precision` digits in all, into `decimal`. A negative scale needs
   -scale trailing zeros, which the unscaled value drops. */
int zar_parse_decimal(const char *s, struct ArrowDecimal *decimal) {
  char digits[96];
  size_t n = 0;
  if (*s == '-' || *s == '+') digits[n++] = *s++;
  size_t first = n;
  if (!zar_digit(*s)) return EINVAL;
  while (zar_digit(*s)) {
    if (n >= sizeof(digits) - 1) return ERANGE;
    digits[n++] = *s++;
  }
  int32_t frac = 0;
  if (*s == '.') {
    s++;
    if (!zar_digit(*s)) return EINVAL;
    while (zar_digit(*s)) {
      if (n >= sizeof(digits) - 1) return ERANGE;
      digits[n++] = *s++;
      frac++;
    }
  }
  if (*s != '\0') return EINVAL;
  if (decimal->scale < 0) {
    /* A negative scale counts trailing zeros of the integer part: a zero
       fraction is dropped, then exactly -scale zeros are, unless the value
       is zero. */
    for (; frac > 0; frac--) {
      if (digits[--n] != '0') return ERANGE;
    }
    size_t zeros = 0;
    while (zeros < n - first && digits[n - 1 - zeros] == '0') zeros++;
    if (zeros == n - first) {
      n = first + 1;
    } else {
      if (zeros < (size_t)-decimal->scale) return ERANGE;
      n -= (size_t)-decimal->scale;
    }
  }
  if (decimal->scale >= 0 && frac > decimal->scale) return ERANGE;
  for (int32_t k = frac; k < decimal->scale; k++) {
    if (n >= sizeof(digits) - 1) return ERANGE;
    digits[n++] = '0';
  }
  digits[n] = '\0';
  /* Count significant digits against the precision. */
  size_t lead = first;
  while (lead < n - 1 && digits[lead] == '0') lead++;
  if ((int32_t)(n - lead) > decimal->precision) return ERANGE;
  struct ArrowStringView view = {digits, (int64_t)n};
  return ArrowDecimalSetDigits(decimal, view);
}

/* Days since 1970-01-01 from a civil date (H. Hinnant's algorithm). */
static int64_t zar_days_from_civil(int64_t y, int m, int d) {
  y -= m <= 2;
  int64_t era = (y >= 0 ? y : y - 399) / 400;
  int64_t yoe = y - era * 400;
  int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
  int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

static int zar_days_in_month(int64_t y, int m) {
  static const int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  int leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
  return m == 2 && leap ? 29 : days[m - 1];
}

static int zar_fixed(const char **s, int width, int *out) {
  int v = 0;
  for (int k = 0; k < width; k++) {
    if (!zar_digit((*s)[k])) return EINVAL;
    v = v * 10 + ((*s)[k] - '0');
  }
  *s += width;
  *out = v;
  return NANOARROW_OK;
}

/* "YYYY-MM-DD", the year signed and longer outside 0000-9999. */
static int zar_parse_date_part(const char **s, int64_t *days) {
  int neg = 0;
  if (**s == '-' || **s == '+') {
    neg = **s == '-';
    (*s)++;
  }
  int64_t y = 0;
  int n = 0;
  while (zar_digit(**s)) {
    if (n >= 9) return ERANGE;
    y = y * 10 + (**s - '0');
    (*s)++;
    n++;
  }
  if (n < 4 || **s != '-') return EINVAL;
  (*s)++;
  if (neg) y = -y;
  int m, d;
  if (zar_fixed(s, 2, &m) != NANOARROW_OK || **s != '-') return EINVAL;
  (*s)++;
  if (zar_fixed(s, 2, &d) != NANOARROW_OK) return EINVAL;
  if (m < 1 || m > 12 || d < 1 || d > zar_days_in_month(y, m)) return EINVAL;
  *days = zar_days_from_civil(y, m, d);
  return NANOARROW_OK;
}

/* ".digits" with at most `digits` of them, scaled to the unit. */
static int zar_parse_fraction(const char **s, int digits, int64_t *out) {
  *out = 0;
  if (**s != '.') return NANOARROW_OK;
  (*s)++;
  int n = 0;
  int64_t v = 0;
  while (zar_digit(**s)) {
    if (n >= digits) return ERANGE;
    v = v * 10 + (**s - '0');
    (*s)++;
    n++;
  }
  if (n == 0) return EINVAL;
  for (; n < digits; n++) v *= 10;
  *out = v;
  return NANOARROW_OK;
}

static int64_t zar_pow10(int digits) {
  int64_t v = 1;
  for (int k = 0; k < digits; k++) v *= 10;
  return v;
}

int zar_parse_date(const char *s, int64_t *days) {
  int code = zar_parse_date_part(&s, days);
  if (code != NANOARROW_OK) return code;
  return *s == '\0' ? NANOARROW_OK : EINVAL;
}

/* "YYYY-MM-DDTHH:MM:SS[.f]" and a trailing "Z" when `utc`, in units of
   10^-digits seconds. */
int zar_parse_instant(const char *s, int digits, int utc, int64_t *out) {
  int64_t days;
  int code = zar_parse_date_part(&s, &days);
  if (code != NANOARROW_OK) return code;
  int h, mi, se;
  if (*s++ != 'T') return EINVAL;
  if (zar_fixed(&s, 2, &h) != NANOARROW_OK || *s++ != ':') return EINVAL;
  if (zar_fixed(&s, 2, &mi) != NANOARROW_OK || *s++ != ':') return EINVAL;
  if (zar_fixed(&s, 2, &se) != NANOARROW_OK) return EINVAL;
  if (h > 23 || mi > 59 || se > 59) return EINVAL;
  int64_t frac;
  code = zar_parse_fraction(&s, digits, &frac);
  if (code != NANOARROW_OK) return code;
  if (utc) {
    if (*s++ != 'Z') return EINVAL;
  }
  if (*s != '\0') return EINVAL;
  int64_t secs = days * 86400 + h * 3600 + mi * 60 + se;
  int64_t scaled;
  if (__builtin_mul_overflow(secs, zar_pow10(digits), &scaled) ||
      __builtin_add_overflow(scaled, frac, out)) {
    return ERANGE;
  }
  return NANOARROW_OK;
}

/* "[-]HH:MM:SS[.f]", hours unbounded, in units of 10^-digits seconds. */
int zar_parse_time(const char *s, int digits, int64_t *out) {
  int neg = *s == '-';
  if (neg) s++;
  int64_t h = 0;
  int n = 0;
  while (zar_digit(*s)) {
    if (n >= 12) return ERANGE;
    h = h * 10 + (*s - '0');
    s++;
    n++;
  }
  if (n < 2 || *s++ != ':') return EINVAL;
  int mi, se;
  if (zar_fixed(&s, 2, &mi) != NANOARROW_OK || *s++ != ':') return EINVAL;
  if (zar_fixed(&s, 2, &se) != NANOARROW_OK) return EINVAL;
  if (mi > 59 || se > 59) return EINVAL;
  int64_t frac;
  int code = zar_parse_fraction(&s, digits, &frac);
  if (code != NANOARROW_OK) return code;
  if (*s != '\0') return EINVAL;
  int64_t secs, v;
  if (__builtin_mul_overflow(h, (int64_t)3600, &secs) ||
      __builtin_add_overflow(secs, (int64_t)(mi * 60 + se), &secs) ||
      __builtin_mul_overflow(secs, zar_pow10(digits), &v) ||
      __builtin_add_overflow(v, frac, &v)) {
    return ERANGE;
  }
  *out = neg ? -v : v;
  return NANOARROW_OK;
}
