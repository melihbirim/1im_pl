#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

int32_t add(int32_t x, int32_t y);

int32_t add(int32_t x, int32_t y) {
        return (x + y);
}

int main(void) {
    int32_t result = add(5, 7);
    printf("%d\n", (int)result);
    return 0;
}
