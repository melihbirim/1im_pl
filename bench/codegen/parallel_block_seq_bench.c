#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

void work1();
void work2();
void work3();
void work4();

void work1() {
        int64_t start = 0;
        int64_t n = 1000000000;
        volatile int64_t sum = 0;
        for (int64_t i = start; i < n; i++) {
            sum = (sum + i);
        }
        printf("%" PRId64 "\n", (int64_t)sum);
}

void work2() {
        int64_t start = 0;
        int64_t n = 1000000000;
        volatile int64_t sum = 0;
        for (int64_t i = start; i < n; i++) {
            sum = (sum + i);
        }
        printf("%" PRId64 "\n", (int64_t)sum);
}

void work3() {
        int64_t start = 0;
        int64_t n = 1000000000;
        volatile int64_t sum = 0;
        for (int64_t i = start; i < n; i++) {
            sum = (sum + i);
        }
        printf("%" PRId64 "\n", (int64_t)sum);
}

void work4() {
        int64_t start = 0;
        int64_t n = 1000000000;
        volatile int64_t sum = 0;
        for (int64_t i = start; i < n; i++) {
            sum = (sum + i);
        }
        printf("%" PRId64 "\n", (int64_t)sum);
}

int main(void) {
    work1();
    work2();
    work3();
    work4();
    return 0;
}
