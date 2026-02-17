#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>


int main(void) {
    int32_t n = 5;
    int32_t result = 1;
    while ((n > 1)) {
        result = (result * n);
        n = (n - 1);
    }
    printf("%d\n", (int)result);
    return 0;
}
