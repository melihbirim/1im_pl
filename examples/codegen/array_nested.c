#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>


int main(void) {
    int32_t grid[2][3] = {{1, 2, 3}, {4, 5, 6}};
    printf("%d\n", (int)grid[1][2]);
    return 0;
}
