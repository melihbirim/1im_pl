#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

int32_t mul(int32_t a, int32_t b);

int32_t mul(int32_t a, int32_t b) {
        return (a * b);
}

int main(void) {
    int32_t result = mul(6, 7);
    printf("%d\n", (int)result);
    return 0;
}
