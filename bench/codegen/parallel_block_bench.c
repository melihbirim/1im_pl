#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

static void* __1im_par_runner(void* arg) { void (*fn)(void) = *(void (**)(void))arg; fn(); return NULL; }

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
    pthread_t __par_threads0[4];
    void (*__par_fns1[4])(void) = { (void (*)(void))work1, (void (*)(void))work2, (void (*)(void))work3, (void (*)(void))work4 };
    pthread_create(&__par_threads0[0], NULL, __1im_par_runner, (void*)&__par_fns1[0]);
    pthread_create(&__par_threads0[1], NULL, __1im_par_runner, (void*)&__par_fns1[1]);
    pthread_create(&__par_threads0[2], NULL, __1im_par_runner, (void*)&__par_fns1[2]);
    pthread_create(&__par_threads0[3], NULL, __1im_par_runner, (void*)&__par_fns1[3]);
    pthread_join(__par_threads0[0], NULL);
    pthread_join(__par_threads0[1], NULL);
    pthread_join(__par_threads0[2], NULL);
    pthread_join(__par_threads0[3], NULL);
    return 0;
}
