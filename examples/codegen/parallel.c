#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

static void* __1im_par_runner(void* arg) { void (*fn)(void) = *(void (**)(void))arg; fn(); return NULL; }

void show_a();
void show_b();

void show_a() {
        printf("%d\n", (int)100);
}

void show_b() {
        printf("%d\n", (int)200);
}

int main(void) {
    int32_t nums[4] = {1, 2, 3, 4};
    {
        #pragma omp parallel for
        for (size_t __i0 = 0; __i0 < 4; __i0++) {
            int32_t n = nums[__i0];
            printf("%d\n", (int)n);
        }
    }
    pthread_t __par_threads2[2];
    void (*__par_fns3[2])(void) = { (void (*)(void))show_a, (void (*)(void))show_b };
    pthread_create(&__par_threads2[0], NULL, __1im_par_runner, (void*)&__par_fns3[0]);
    pthread_create(&__par_threads2[1], NULL, __1im_par_runner, (void*)&__par_fns3[1]);
    pthread_join(__par_threads2[0], NULL);
    pthread_join(__par_threads2[1], NULL);
    return 0;
}
