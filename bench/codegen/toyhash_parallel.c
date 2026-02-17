#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

static void* __1im_par_runner(void* arg) { void (*fn)(void) = *(void (**)(void))arg; fn(); return NULL; }

void worker1();
void worker2();
void worker3();
void worker4();

void worker1() {
        int64_t start = 0;
        int64_t runs = 2500;
        int64_t inner = 1000;
        int64_t mod = 2147483647;
        int64_t h = 7;
        for (int64_t r = start; r < runs; r++) {
            int64_t i = 0;
            while ((i < inner)) {
                h = ((((h * 31) + i) + r) % mod);
                i = (i + 1);
            }
        }
        printf("%" PRId64 "\n", (int64_t)h);
}

void worker2() {
        int64_t start = 0;
        int64_t runs = 2500;
        int64_t inner = 1000;
        int64_t mod = 2147483647;
        int64_t h = 11;
        for (int64_t r = start; r < runs; r++) {
            int64_t i = 0;
            while ((i < inner)) {
                h = ((((h * 31) + i) + r) % mod);
                i = (i + 1);
            }
        }
        printf("%" PRId64 "\n", (int64_t)h);
}

void worker3() {
        int64_t start = 0;
        int64_t runs = 2500;
        int64_t inner = 1000;
        int64_t mod = 2147483647;
        int64_t h = 13;
        for (int64_t r = start; r < runs; r++) {
            int64_t i = 0;
            while ((i < inner)) {
                h = ((((h * 31) + i) + r) % mod);
                i = (i + 1);
            }
        }
        printf("%" PRId64 "\n", (int64_t)h);
}

void worker4() {
        int64_t start = 0;
        int64_t runs = 2500;
        int64_t inner = 1000;
        int64_t mod = 2147483647;
        int64_t h = 17;
        for (int64_t r = start; r < runs; r++) {
            int64_t i = 0;
            while ((i < inner)) {
                h = ((((h * 31) + i) + r) % mod);
                i = (i + 1);
            }
        }
        printf("%" PRId64 "\n", (int64_t)h);
}

int main(void) {
    pthread_t __par_threads0[4];
    void (*__par_fns1[4])(void) = { (void (*)(void))worker1, (void (*)(void))worker2, (void (*)(void))worker3, (void (*)(void))worker4 };
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
