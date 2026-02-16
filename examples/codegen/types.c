#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>


int main(void) {
    int8_t small = 42;
    int32_t medium = 1000;
    int64_t large = 999999;
    uint8_t byte = 255;
    uint32_t word = 65535;
    float ratio = 3.14;
    double precise = 2.71828;
    bool flag = true;
    bool nope = false;
    printf("%d\n", (int)small);
    printf("%d\n", (int)medium);
    printf("%" PRId64 "\n", (int64_t)large);
    printf("%u\n", (unsigned int)byte);
    printf("%u\n", (unsigned int)word);
    printf("%f\n", (float)ratio);
    printf("%f\n", (double)precise);
    printf("%s\n", flag ? "true" : "false");
    printf("%s\n", nope ? "true" : "false");
    return 0;
}
