#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>


int main(void) {
    for (int32_t i = 0; i < 5; i++) {
        printf("%d\n", (int)i);
    }
    for (int32_t j = 1; j <= 3; j++) {
        printf("%d\n", (int)j);
    }
    return 0;
}
