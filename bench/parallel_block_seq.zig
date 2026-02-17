const std = @import("std");

fn work(n: i64) i64 {
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        sum += i;
    }
    return sum;
}

pub fn main() void {
    const n: i64 = 200000000;
    const a = work(n);
    const b = work(n);
    const c = work(n);
    const d = work(n);
    std.debug.print("{}\n{}\n{}\n{}\n", .{ a, b, c, d });
}
