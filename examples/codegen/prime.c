#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>


int main(void) {
    int32_t n = 29;
    bool is_prime = true;
    if ((n < 2)) {
        is_prime = false;
    } else {
        int32_t i = 2;
        while (((i * i) <= n)) {
            if (((n % i) == 0)) {
                is_prime = false;
            }
            i = (i + 1);
        }
    }
    printf("%s\n", is_prime ? "true" : "false");
    return 0;
}
