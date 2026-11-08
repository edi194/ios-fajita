// A dylib with chained fixups: rebases and binds in data, signed (arm64e) and plain pointers.
#include <stdio.h>
#include <stdlib.h>

static int local(int x) { return x + 1; }
int (*fp_local)(int) = local;
int (*fp_puts)(const char *) = puts;
void *(*fp_malloc)(size_t) = malloc;
const char *strings[] = {"a", "b", "c"};
int call(int x) { return fp_local(x) + (fp_puts ? 1 : 0); }
