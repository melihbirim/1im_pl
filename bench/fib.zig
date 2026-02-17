const std = @import("std");

pub fn main() void {
    const N: i64 = 35;
    const REPEAT: i64 = 50000000;

    var rep: i64 = 0;
    var total: i64 = 0;

    while (rep < REPEAT) : (rep += 1) {
        var a: i64 = 0;
        var b: i64 = 1;
        var i: i64 = 0;
        while (i < N) : (i += 1) {
            const next = a + b;
            a = b;
            b = next;
        }
        total += a + rep;
    }

    std.debug.print("{}\n", .{total});
}
