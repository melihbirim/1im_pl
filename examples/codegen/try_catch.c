#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>
#include <pthread.h>

typedef struct { bool ok; int32_t value; const char* err; } err_i32_str;
static inline err_i32_str err_i32_str_ok(int32_t value) { return (err_i32_str){ .ok = true, .value = value, .err = NULL }; }
static inline err_i32_str err_i32_str_err(const char* err) { return (err_i32_str){ .ok = false, .value = (int32_t){0}, .err = err }; }

err_i32_str fail();

err_i32_str fail() {
        return err_i32_str_err("boom");
}

int main(void) {
    {
        err_i32_str __try0 = fail();
        if (!__try0.ok) {
            const char* err = __try0.err;
            printf("%s\n", err);
        }
    }
    return 0;
}
