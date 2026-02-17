#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>


int main(void) {
    int32_t a = 0;
    int32_t b = 1;
    int32_t i = 0;
    while ((i < 10)) {
        printf("%d\n", (int)a);
        int32_t next = (a + b);
        a = b;
        b = next;
        i = (i + 1);
    }
    return 0;
}
