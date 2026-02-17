#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>


int main(void) {
    int32_t counter = 0;
    while ((counter < 5)) {
        printf("%d\n", (int)counter);
        counter = (counter + 1);
    }
    printf("%d\n", (int)999);
    return 0;
}
