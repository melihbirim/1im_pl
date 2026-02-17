const std = @import("std");

pub fn main() void {
    const N: i32 = 5000;
    const REPEAT: i32 = 5000;

    var rep: i32 = 0;
    var total: i32 = 0;

    while (rep < REPEAT) : (rep += 1) {
        var count: i32 = 0;
        var n: i32 = 2;
        while (n <= N) : (n += 1) {
            var is_prime = true;
            var i: i32 = 2;
            while (i * i <= n) : (i += 1) {
                if (@mod(n, i) == 0) {
                    is_prime = false;
                }
            }
            if (is_prime) count += 1;
        }
        total += count;
    }

    std.debug.print("{}\n", .{total});
}
