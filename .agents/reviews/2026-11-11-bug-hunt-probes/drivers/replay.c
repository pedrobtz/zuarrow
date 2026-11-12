/* Replays files through LLVMFuzzerTestOneInput (no libFuzzer on Apple clang). */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    FILE *f = fopen(argv[i], "rb"); if (!f) { perror(argv[i]); continue; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *buf = malloc(n ? n : 1); fread(buf, 1, n, f); fclose(f);
    LLVMFuzzerTestOneInput(buf, (size_t)n); free(buf);
  }
  return 0;
}
