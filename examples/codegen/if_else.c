#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>


int main(void) {
    int32_t x = 10;
    if ((x > 5)) {
        printf("%d\n", (int)1);
    } else {
        printf("%d\n", (int)0);
    }
    int32_t age = 25;
    if ((age < 18)) {
        printf("%d\n", (int)0);
    } else if ((age < 65)) {
        printf("%d\n", (int)1);
    } else {
        printf("%d\n", (int)2);
    }
    return 0;
}
