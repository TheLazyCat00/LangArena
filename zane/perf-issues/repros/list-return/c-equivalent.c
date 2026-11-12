#include <stdio.h>
#include <stdlib.h>
/* The same rounds in C: a growing array of n longs per round, freed after. */
int main(int argc, char **argv) {
  long n = atol(argv[1]), rounds = atol(argv[2]), total = 0;
  for (long r = 1; r <= rounds; r++) {
    long cap = 4, count = 0, *items = malloc(cap * sizeof *items);
    for (long i = 1; i <= n; i++) {
      if (count == cap) items = realloc(items, (cap *= 2) * sizeof *items);
      items[count++] = i + r;
    }
    total += items[n - 1];
    free(items);
  }
  printf("%ld\n", total);
}
