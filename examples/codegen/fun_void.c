#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

void say(int32_t x);

void say(int32_t x) {
        printf("%d\n", (int)x);
}

int main(void) {
    say(123);
    return 0;
}
