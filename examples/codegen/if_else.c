#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>


int main(void) {
    int32_t x = 10;
    if ((x > 5)) {
        printf("%" PRId64 "\n", (int64_t)1);
    } else {
        printf("%" PRId64 "\n", (int64_t)0);
    }
    int32_t age = 25;
    if ((age < 18)) {
        printf("%" PRId64 "\n", (int64_t)0);
    } else if ((age < 65)) {
        printf("%" PRId64 "\n", (int64_t)1);
    } else {
        printf("%" PRId64 "\n", (int64_t)2);
    }
    return 0;
}
