const std = @import("std");

fn work(n: i64) i64 {
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        sum += i;
    }
    return sum;
}

const ThreadCtx = struct {
    n: *const i64,
    out: *i64,
};

fn threadMain(ctx: *ThreadCtx) !void {
    const n = ctx.n.*;
    ctx.out.* = work(n);
}

pub fn main() !void {
    const n: i64 = 1000000000;
    var threads: [4]std.Thread = undefined;
    var args: [4]i64 = .{ n, n, n, n };
    var results: [4]i64 = .{ 0, 0, 0, 0 };
    var ctxs: [4]ThreadCtx = .{
        .{ .n = &args[0], .out = &results[0] },
        .{ .n = &args[1], .out = &results[1] },
        .{ .n = &args[2], .out = &results[2] },
        .{ .n = &args[3], .out = &results[3] },
    };

    threads[0] = try std.Thread.spawn(.{}, threadMain, .{&ctxs[0]});
    threads[1] = try std.Thread.spawn(.{}, threadMain, .{&ctxs[1]});
    threads[2] = try std.Thread.spawn(.{}, threadMain, .{&ctxs[2]});
    threads[3] = try std.Thread.spawn(.{}, threadMain, .{&ctxs[3]});

    threads[0].join();
    threads[1].join();
    threads[2].join();
    threads[3].join();

    const total = results[0] + results[1] + results[2] + results[3];
    std.debug.print("{}\n", .{total});
}
