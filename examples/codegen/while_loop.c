#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>


int main(void) {
    int32_t counter = 0;
    while ((counter < 5)) {
        printf("%d\n", (int)counter);
        counter = (counter + 1);
    }
    printf("%" PRId64 "\n", (int64_t)999);
    return 0;
}
