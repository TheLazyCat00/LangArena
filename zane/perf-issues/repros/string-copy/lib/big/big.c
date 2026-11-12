#include "big.h"
#include <string.h>
/* A fresh string of `n` bytes, made as any foreign call returning one makes it. */
zane_bytes big_make(int64_t n) {
  uint8_t *p = zane_bytes_alloc((size_t)n);
  memset(p, 'a', (size_t)n);
  return (zane_bytes){p, (size_t)n};
}
int64_t big_length(zane_bytes text) { return (int64_t)text.size; }
