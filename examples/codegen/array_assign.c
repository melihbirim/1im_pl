#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>


int main(void) {
    int32_t nums[3] = {1, 2, 3};
    nums[1] = 9;
    printf("%d\n", (int)nums[0]);
    printf("%d\n", (int)nums[1]);
    printf("%d\n", (int)nums[2]);
    return 0;
}
