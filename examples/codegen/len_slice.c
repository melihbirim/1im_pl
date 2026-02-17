#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

typedef struct { int32_t* data; size_t len; } slice_i32;


int main(void) {
    int32_t slice_data[4] = {7, 8, 9, 10};
    slice_i32 slice = { slice_data, 4 };
    printf("%d\n", (int)slice.len);
    return 0;
}
