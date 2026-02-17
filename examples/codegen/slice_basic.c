#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

typedef struct { int32_t* data; size_t len; } slice_i32;


int main(void) {
    int32_t slice_data[3] = {4, 5, 6};
    slice_i32 slice = { slice_data, 3 };
    printf("%d\n", (int)slice.data[0]);
    printf("%d\n", (int)slice.data[2]);
    return 0;
}
