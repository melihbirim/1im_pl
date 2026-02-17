#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>


int main(void) {
    int32_t a = 48;
    int32_t b = 18;
    while ((b != 0)) {
        int32_t temp = b;
        b = (a % b);
        a = temp;
    }
    printf("%d\n", (int)a);
    return 0;
}
