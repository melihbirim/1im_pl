const std = @import("std");

fn worker(seed: i64, runs: i64, inner: i64, modu: i64) i64 {
    var h: i64 = seed;
    var r: i64 = 0;
    while (r < runs) : (r += 1) {
        var i: i64 = 0;
        while (i < inner) : (i += 1) {
            h = @mod(h * 31 + i + r, modu);
        }
    }
    return h;
}

pub fn main() void {
    const runs: i64 = 2500;
    const inner: i64 = 1000;
    const modu: i64 = 2147483647;
    const a = worker(7, runs, inner, modu);
    const b = worker(11, runs, inner, modu);
    const c = worker(13, runs, inner, modu);
    const d = worker(17, runs, inner, modu);
    std.debug.print("{}\n{}\n{}\n{}\n", .{ a, b, c, d });
}
