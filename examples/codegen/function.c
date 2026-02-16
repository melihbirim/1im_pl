#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>

int32_t add(int32_t x, int32_t y);

int32_t add(int32_t x, int32_t y) {
        return (x + y);
}

int main(void) {
    int64_t result = add(5, 3);
    printf("%" PRId64 "\n", (int64_t)result);
    return 0;
}
