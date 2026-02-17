const std = @import("std");

pub fn main() !void {
    const N: usize = 10000;
    const REPEAT: usize = 5000;

    var values: [N]i32 = undefined;
    var left: [N]i32 = undefined;
    var right: [N]i32 = undefined;
    var stack: [N]i32 = undefined;

    var i: usize = 0;
    while (i < N) : (i += 1) {
        values[i] = @intCast(i);

        const li = @as(i32, @intCast(i)) * 2 + 1;
        if (@as(usize, @intCast(li)) < N) {
            left[i] = li;
        } else {
            left[i] = -1;
        }

        const ri = @as(i32, @intCast(i)) * 2 + 2;
        if (@as(usize, @intCast(ri)) < N) {
            right[i] = ri;
        } else {
            right[i] = -1;
        }
    }

    var sum: i32 = 0;
    var rep: usize = 0;
    while (rep < REPEAT) : (rep += 1) {
        var top: i32 = 0;
        stack[@intCast(top)] = 0;
        top += 1;
        sum = 0;

        while (top > 0) {
            top -= 1;
            const node = stack[@intCast(top)];
            sum += values[@intCast(node)];

            const l = left[@intCast(node)];
            if (l != -1) {
                stack[@intCast(top)] = l;
                top += 1;
            }

            const r = right[@intCast(node)];
            if (r != -1) {
                stack[@intCast(top)] = r;
                top += 1;
            }
        }
    }

    std.mem.doNotOptimizeAway(sum);
}
