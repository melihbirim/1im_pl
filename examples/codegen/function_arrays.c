#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

typedef struct { int32_t value[3]; } arrret_arr3_i32;
typedef struct { int32_t* data; size_t len; } slice_i32;

int32_t first(int32_t nums[3]);
arrret_arr3_i32 make3();
slice_i32 id_slice(slice_i32 nums);

int32_t first(int32_t nums[3]) {
        return nums[0];
}

arrret_arr3_i32 make3() {
        return (arrret_arr3_i32){ .value = {7, 8, 9} };
}

slice_i32 id_slice(slice_i32 nums) {
        return nums;
}

int main(void) {
    int32_t arr[3];
    memcpy(arr, (make3()).value, sizeof(arr));
    printf("%d\n", (int)first(arr));
    int32_t s_data[3] = {4, 5, 6};
    slice_i32 s = { s_data, 3 };
    slice_i32 s2 = id_slice(s);
    printf("%d\n", (int)s2.data[1]);
    return 0;
}
