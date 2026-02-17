#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

typedef struct { int32_t* data; size_t len; } slice_i32;


int main(void) {
    int32_t nums[3] = {1, 2, 3};
    {
        for (size_t __i0 = 0; __i0 < 3; __i0++) {
            int32_t n = nums[__i0];
            printf("%d\n", (int)n);
        }
    }
    int32_t s_data[3] = {4, 5, 6};
    slice_i32 s = { s_data, 3 };
    {
        slice_i32 __iter3 = s;
        for (size_t __i2 = 0; __i2 < __iter3.len; __i2++) {
            int32_t x = __iter3.data[__i2];
            printf("%d\n", (int)x);
        }
    }
    return 0;
}
