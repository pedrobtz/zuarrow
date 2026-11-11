/* A replay of the IPC corpus through the reader built without R
   (ZAR_STANDALONE), for mutation testing (#183). Unlike the fuzz target,
   which fails only on a crash, it compares each input's outcome with the
   one recorded for it and exits 1 on any difference, so a change to the
   reader that alters a result kills the mutant.

   Run from the package root, with tests/testthat/fixtures fetched
   (tools/fetch-fixtures):

     tools/fuzz/replay            check every expected outcome
     tools/fuzz/replay --record   print the golden outcomes, for
                                  tools/fuzz/replay-expected.csv

   Two tables give the outcomes:

   - tests/testthat/crash-expected.csv, the crash corpus, which the R tests
     also read: each input is refused with the condition class it names.
   - tools/fuzz/replay-expected.csv, the golden files of fixtures-files.txt:
     "ok" with the row count, the batch count and an FNV-1a digest of every
     buffer each batch decodes to, or the class of the failure. Without R
     there are no codecs, so the compressed cases fail as codec errors.

   A path is under tests/testthat when it starts with data/, and under
   tests/testthat/fixtures otherwise. The limits are arrow_limits()'s
   defaults, as arrow_read() uses them. A built-in table of UTF-8 cases
   checks zar_utf8_invalid_at(), whose rejections the corpus barely
   exercises. */
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zar.h"

#define ZAR_TESTS "tests/testthat/"
#define ZAR_CRASH ZAR_TESTS "crash-expected.csv"
#define ZAR_GOLDEN "tools/fuzz/replay-expected.csv"
#define ZAR_FILES ZAR_TESTS "fixtures-files.txt"

struct zar_outcome {
  char expect[64]; /* "ok", or a condition class */
  int64_t rows;
  int64_t batches;
  uint64_t digest;
};

static int zar_failures = 0;

static uint64_t zar_fnv(uint64_t h, const void *p, int64_t n) {
  const uint8_t *b = (const uint8_t *)p;
  for (int64_t i = 0; i < n; i++) {
    h ^= b[i];
    h *= 1099511628211ULL;
  }
  return h;
}

static uint64_t zar_digest_view(uint64_t h, const struct ArrowArrayView *v) {
  h = zar_fnv(h, &v->length, sizeof(v->length));
  h = zar_fnv(h, &v->offset, sizeof(v->offset));
  h = zar_fnv(h, &v->null_count, sizeof(v->null_count));
  for (int i = 0; i < NANOARROW_MAX_FIXED_BUFFERS; i++) {
    const struct ArrowBufferView *b = &v->buffer_views[i];
    h = zar_fnv(h, &b->size_bytes, sizeof(b->size_bytes));
    if (b->data.data != NULL && b->size_bytes > 0) h = zar_fnv(h, b->data.data, b->size_bytes);
  }
  for (int64_t i = 0; i < v->n_variadic_buffers; i++) {
    h = zar_fnv(h, &v->variadic_buffer_sizes[i], sizeof(int64_t));
    h = zar_fnv(h, v->variadic_buffers[i], v->variadic_buffer_sizes[i]);
  }
  for (int64_t i = 0; i < v->n_children; i++) h = zar_digest_view(h, v->children[i]);
  if (v->dictionary != NULL) h = zar_digest_view(h, v->dictionary);
  return h;
}

static void zar_class_of(const char *kind, char *out, size_t n) {
  if (kind == NULL) {
    snprintf(out, n, "zuarrow_error");
  } else {
    snprintf(out, n, "zuarrow_%s_error", kind);
  }
}

/* Reads the whole input at `path` into memory; NULL when it cannot. */
static uint8_t *zar_slurp(const char *path, int64_t *size) {
  FILE *f = fopen(path, "rb");
  if (f == NULL) return NULL;
  uint8_t *data = NULL;
  int64_t n = 0, cap = 0;
  for (;;) {
    if (n == cap) {
      cap = cap ? cap * 2 : 65536;
      uint8_t *grown = (uint8_t *)realloc(data, (size_t)cap);
      if (grown == NULL) {
        free(data);
        fclose(f);
        return NULL;
      }
      data = grown;
    }
    size_t got = fread(data + n, 1, (size_t)(cap - n), f);
    n += (int64_t)got;
    if (got == 0) break;
  }
  fclose(f);
  *size = n;
  return data;
}

static void zar_path_of(const char *file, char *out, size_t n) {
  if (strncmp(file, "data/", 5) == 0) {
    snprintf(out, n, ZAR_TESTS "%s", file);
  } else {
    snprintf(out, n, ZAR_TESTS "fixtures/%s", file);
  }
}

/* Opens and reads `file` to its end. Returns 0, or 2 when the file cannot
   be read at all, which is a broken setup and not a mutant's doing. */
static int zar_replay(const char *file, struct zar_outcome *out) {
  char path[1024];
  zar_path_of(file, path, sizeof(path));
  int64_t size = 0;
  uint8_t *data = zar_slurp(path, &size);
  if (data == NULL) {
    fprintf(stderr, "replay: cannot read %s (run tools/fetch-fixtures)\n", path);
    return 2;
  }
  const double limits[5] = {pow(2, 31) - 1, 64.0, pow(2, 31) - 1, INFINITY, pow(2, 28)};
  memset(out, 0, sizeof(*out));
  out->digest = 14695981039346656037ULL;
  struct ArrowArrayStream stream;
  struct ArrowError error;
  error.message[0] = '\0';
  const char *kind = NULL;
  int code = zar_reader_open_bytes(data, size, limits, &stream, &error, &kind);
  free(data);
  if (code != 0) {
    zar_class_of(kind, out->expect, sizeof(out->expect));
    return 0;
  }
  struct ArrowSchema schema;
  schema.release = NULL;
  code = stream.get_schema(&stream, &schema);
  if (code != 0) {
    zar_class_of(zar_reader_recorded_kind(&stream), out->expect, sizeof(out->expect));
    stream.release(&stream);
    return 0;
  }
  snprintf(out->expect, sizeof(out->expect), "ok");
  for (;;) {
    struct ArrowArray array;
    array.release = NULL;
    code = stream.get_next(&stream, &array);
    if (code != 0) {
      zar_class_of(zar_reader_recorded_kind(&stream), out->expect, sizeof(out->expect));
      break;
    }
    if (array.release == NULL) break;
    out->batches++;
    out->rows += array.length;
    struct ArrowArrayView view;
    if (ArrowArrayViewInitFromSchema(&view, &schema, &error) == NANOARROW_OK &&
        ArrowArrayViewSetArray(&view, &array, &error) == NANOARROW_OK) {
      out->digest = zar_digest_view(out->digest, &view);
    } else {
      /* The reader handed out a batch its own schema cannot view. */
      snprintf(out->expect, sizeof(out->expect), "unviewable");
    }
    ArrowArrayViewReset(&view);
    array.release(&array);
  }
  schema.release(&schema);
  stream.release(&stream);
  return 0;
}

/* Splits one CSV line into at most `max` fields in place, honouring double
   quotes. Returns the number of fields. */
static int zar_csv_split(char *line, char **fields, int max) {
  int n = 0;
  char *p = line;
  while (n < max) {
    char *start = p, *w = p;
    int quoted = (*p == '"');
    if (quoted) p++;
    for (;;) {
      if (*p == '\0' || *p == '\n' || *p == '\r') break;
      if (quoted && *p == '"') {
        if (p[1] == '"') {
          *w++ = '"';
          p += 2;
          continue;
        }
        quoted = 0;
        p++;
        continue;
      }
      if (!quoted && *p == ',') break;
      *w++ = *p++;
    }
    char end = *p;
    *w = '\0';
    fields[n++] = start;
    if (end != ',') break;
    p++;
  }
  return n;
}

/* Checks every row of the table at `table`: `with_rows` for the golden
   table's file,expect,rows,batches,digest; the crash table is
   file,expect,note. Returns 0, or 2 on a broken setup. */
static int zar_check_table(const char *table, int with_rows, int *checked) {
  FILE *f = fopen(table, "r");
  if (f == NULL) {
    fprintf(stderr, "replay: cannot read %s\n", table);
    return 2;
  }
  char line[4096];
  int header = 1;
  while (fgets(line, sizeof(line), f) != NULL) {
    if (line[0] == '#' || line[0] == '\n') continue;
    if (header) {
      header = 0;
      continue;
    }
    char *fields[5];
    int n = zar_csv_split(line, fields, 5);
    if (n < 2 || (with_rows && n < 5)) {
      fprintf(stderr, "replay: %s: a malformed row: %s\n", table, fields[0]);
      fclose(f);
      return 2;
    }
    struct zar_outcome got;
    if (zar_replay(fields[0], &got) != 0) {
      fclose(f);
      return 2;
    }
    (*checked)++;
    int same = strcmp(got.expect, fields[1]) == 0;
    if (same && with_rows && strcmp(got.expect, "ok") == 0) {
      char digest[32];
      snprintf(digest, sizeof(digest), "%016llx", (unsigned long long)got.digest);
      same = got.rows == strtoll(fields[2], NULL, 10) &&
             got.batches == strtoll(fields[3], NULL, 10) && strcmp(digest, fields[4]) == 0;
    }
    if (!same) {
      zar_failures++;
      fprintf(stderr, "replay: %s: expected %s", fields[0], fields[1]);
      if (with_rows) fprintf(stderr, " %s %s %s", fields[2], fields[3], fields[4]);
      fprintf(stderr, ", got %s %lld %lld %016llx\n", got.expect, (long long)got.rows,
              (long long)got.batches, (unsigned long long)got.digest);
    }
  }
  fclose(f);
  return 0;
}

/* Prints the golden table: every integration file fixtures-files.txt
   lists, other than the JSON twins. */
static int zar_record(void) {
  FILE *f = fopen(ZAR_FILES, "r");
  if (f == NULL) {
    fprintf(stderr, "replay: cannot read %s\n", ZAR_FILES);
    return 2;
  }
  printf("file,expect,rows,batches,digest\n");
  char line[1024];
  while (fgets(line, sizeof(line), f) != NULL) {
    line[strcspn(line, "\r\n")] = '\0';
    if (line[0] == '#' || strstr(line, "/integration/") == NULL) continue;
    size_t n = strlen(line);
    if (n > 8 && strcmp(line + n - 8, ".json.gz") == 0) continue;
    struct zar_outcome got;
    if (zar_replay(line, &got) != 0) {
      fclose(f);
      return 2;
    }
    if (strcmp(got.expect, "ok") == 0) {
      printf("%s,ok,%lld,%lld,%016llx\n", line, (long long)got.rows, (long long)got.batches,
             (unsigned long long)got.digest);
    } else {
      printf("%s,%s,,,\n", line, got.expect);
    }
  }
  fclose(f);
  return 0;
}

/* Byte strings and the offset of their first invalid byte, -1 for valid
   UTF-8 (RFC 3629, and Markus Kuhn's decoder stress test). Each sits
   after nine ASCII bytes too, so the eight-byte fast path hands over to
   the byte loop mid-word. */
static const struct {
  const char *bytes;
  int64_t size;
  int64_t invalid_at;
} zar_utf8_cases[] = {
    {"", 0, -1},
    {"abc", 3, -1},
    {"\xc2\x80", 2, -1},             /* U+0080, the first two-byte form */
    {"\xdf\xbf", 2, -1},             /* U+07FF */
    {"\xe0\xa0\x80", 3, -1},         /* U+0800 */
    {"\xed\x9f\xbf", 3, -1},         /* U+D7FF, below the surrogates */
    {"\xee\x80\x80", 3, -1},         /* U+E000, above them */
    {"\xef\xbf\xbf", 3, -1},         /* U+FFFF */
    {"\xf0\x90\x80\x80", 4, -1},     /* U+10000 */
    {"\xf4\x8f\xbf\xbf", 4, -1},     /* U+10FFFF, the last code point */
    {"a\xc3\xa9z", 4, -1},           /* é between ASCII */
    {"\x80", 1, 0},                  /* a lone continuation byte */
    {"\xbf", 1, 0},
    {"\xc0\x80", 2, 0},              /* overlong NUL */
    {"\xc1\xbf", 2, 0},              /* overlong U+007F */
    {"\xc2", 1, 0},                  /* truncated two-byte form */
    {"\xc2\x41", 2, 0},              /* a non-continuation second byte */
    {"\xc2\xc0", 2, 0},
    {"\xe0\x80\x80", 3, 0},          /* overlong U+0000 */
    {"\xe0\x9f\xbf", 3, 0},          /* overlong U+07FF */
    {"\xed\xa0\x80", 3, 0},          /* U+D800, the first surrogate */
    {"\xed\xbf\xbf", 3, 0},          /* U+DFFF, the last */
    {"\xe1\x80", 2, 0},              /* truncated three-byte form */
    {"\xe1\x80\x41", 3, 0},
    {"\xf0\x80\x80\x80", 4, 0},      /* overlong four-byte form */
    {"\xf0\x8f\xbf\xbf", 4, 0},      /* overlong U+FFFF */
    {"\xf4\x90\x80\x80", 4, 0},      /* U+110000 */
    {"\xf5\x80\x80\x80", 4, 0},      /* a lead byte past F4 */
    {"\xf8\x88\x80\x80\x80", 5, 0},  /* a five-byte form */
    {"\xfe", 1, 0},
    {"\xff", 1, 0},
    {"\xf0\x90\x80", 3, 0},          /* truncated four-byte form */
    {"\xf0\x90\x80\x41", 4, 0},
    {"ab\xc3\xa9\x80", 5, 4},        /* valid, then a stray byte */
    {"\xe2\x82\xac\xed\xa0\x80", 6, 3},
};

static int zar_check_utf8(int *checked) {
  uint8_t buf[64];
  for (size_t k = 0; k < sizeof(zar_utf8_cases) / sizeof(zar_utf8_cases[0]); k++) {
    int64_t n = zar_utf8_cases[k].size, want = zar_utf8_cases[k].invalid_at;
    for (int pad = 0; pad <= 9; pad += 9) {
      memset(buf, 'x', (size_t)pad);
      memcpy(buf + pad, zar_utf8_cases[k].bytes, (size_t)n);
      int64_t expect = want < 0 ? -1 : want + pad;
      int64_t got = zar_utf8_invalid_at(buf, n + pad);
      (*checked)++;
      if (got != expect) {
        zar_failures++;
        fprintf(stderr, "replay: utf8 case %d (pad %d): expected %lld, got %lld\n", (int)k,
                pad, (long long)expect, (long long)got);
      }
    }
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--record") == 0) return zar_record();
  if (argc != 1) {
    fprintf(stderr, "usage: tools/fuzz/replay [--record]\n");
    return 2;
  }
  int crash = 0, golden = 0, utf8 = 0;
  if (zar_check_table(ZAR_CRASH, 0, &crash) != 0) return 2;
  if (zar_check_table(ZAR_GOLDEN, 1, &golden) != 0) return 2;
  zar_check_utf8(&utf8);
  printf("replay: %d crash inputs, %d golden inputs, %d utf8 cases, %d mismatched\n", crash,
         golden, utf8, zar_failures);
  return zar_failures == 0 ? 0 : 1;
}
