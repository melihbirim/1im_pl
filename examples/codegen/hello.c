#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>


int main(void) {
    int64_t age = 41;
    printf("%" PRId64 "\n", (int64_t)age);
    return 0;
}
