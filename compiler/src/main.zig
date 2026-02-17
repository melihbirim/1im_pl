/// 1im compiler — main entry point.
/// Usage: 1im <source.1im>
///
/// Pipeline: source → lexer → parser → C codegen → cc → run
const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;
const Parser = @import("parser.zig").Parser;
const Codegen = @import("codegen.zig").Codegen;
const Analyzer = @import("semantic.zig").Analyzer;

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ── Parse CLI args ──────────────────────────────────────────
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        try std.fs.File.stderr().writeAll("usage: 1im <source.1im>\n");
        std.process.exit(1);
    }

    const source_path = args[1];

    // ── Read source file ────────────────────────────────────────
    const source = std.fs.cwd().readFileAlloc(gpa, source_path, 10 * 1024 * 1024) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: cannot read '{s}': {s}\n", .{ source_path, @errorName(err) }) catch "error reading file\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        std.process.exit(1);
    };
    defer gpa.free(source);

    // ── Lex ─────────────────────────────────────────────────────
    var lexer = Lexer.init(gpa, source);
    defer lexer.deinit();

    const tokens = lexer.tokenize() catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "lexer error: {s}\n", .{@errorName(err)}) catch "lexer error\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        std.process.exit(1);
    };

    // ── Parse ───────────────────────────────────────────────────
    var parser = Parser.init(arena, tokens);

    const program = parser.parse() catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "parse error at line {d}:{d}: {s}\n", .{
            parser.currentLine(),
            parser.currentCol(),
            @errorName(err),
        }) catch "parse error\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        std.process.exit(1);
    };

    // ── Semantic Analysis ───────────────────────────────────────
    var analyzer = Analyzer.init(gpa);
    defer analyzer.deinit();

    _ = analyzer.analyze(program) catch {
        const msg = if (analyzer.last_error.len > 0) analyzer.last_error else "semantic error\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        std.fs.File.stderr().writeAll("\n") catch {};
        std.process.exit(1);
    };

    // ── Generate C ──────────────────────────────────────────────
    var codegen = Codegen.init(gpa);
    defer codegen.deinit();

    const c_source = codegen.generate(program) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "codegen error: {s}\n", .{@errorName(err)}) catch "codegen error\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        std.process.exit(1);
    };

    // ── Write C to examples/codegen/ ───────────────────────────
    // Extract basename from source path (e.g., "examples/hello.1im" → "hello")
    const basename = blk: {
        const path_sep_idx = std.mem.lastIndexOfScalar(u8, source_path, '/') orelse 0;
        const filename = if (path_sep_idx > 0) source_path[path_sep_idx + 1 ..] else source_path;
        const ext_idx = std.mem.lastIndexOfScalar(u8, filename, '.') orelse filename.len;
        break :blk filename[0..ext_idx];
    };

    // Determine codegen directory relative to source file
    const codegen_dir = blk: {
        const path_sep_idx = std.mem.lastIndexOfScalar(u8, source_path, '/');
        if (path_sep_idx) |idx| {
            const dir = source_path[0..idx];
            const codegen_path = std.fmt.allocPrint(gpa, "{s}/codegen", .{dir}) catch {
                break :blk "examples/codegen";
            };
            break :blk codegen_path;
        }
        break :blk "examples/codegen";
    };
    defer if (std.mem.indexOf(u8, codegen_dir, "/codegen") != null) gpa.free(codegen_dir);

    // Create codegen directory if it doesn't exist
    std.fs.cwd().makePath(codegen_dir) catch {};

    const c_path = std.fmt.allocPrint(gpa, "{s}/{s}.c", .{ codegen_dir, basename }) catch {
        std.fs.File.stderr().writeAll("error: out of memory\n") catch {};
        std.process.exit(1);
    };
    defer gpa.free(c_path);

    const bin_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ codegen_dir, basename }) catch {
        std.fs.File.stderr().writeAll("error: out of memory\n") catch {};
        std.process.exit(1);
    };
    defer gpa.free(bin_path);

    {
        const c_file = try std.fs.cwd().createFile(c_path, .{});
        defer c_file.close();
        try c_file.writeAll(c_source);
    }

    // ── Compile C → binary ──────────────────────────────────────
    const compile_result = std.process.Child.run(.{
        .allocator = gpa,
        .argv = &.{ "cc", "-o", bin_path, c_path, "-O3", "-march=native", "-pthread" },
    }) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "failed to invoke C compiler: {s}\n", .{@errorName(err)}) catch "failed to invoke C compiler\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        std.process.exit(1);
    };
    defer gpa.free(compile_result.stdout);
    defer gpa.free(compile_result.stderr);

    switch (compile_result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.fs.File.stderr().writeAll("C compilation failed:\n") catch {};
                std.fs.File.stderr().writeAll(compile_result.stderr) catch {};
                std.process.exit(1);
            }
        },
        else => {
            std.fs.File.stderr().writeAll("C compiler terminated abnormally\n") catch {};
            std.process.exit(1);
        },
    }

    // ── Run the binary ──────────────────────────────────────────
    const run_result = std.process.Child.run(.{
        .allocator = gpa,
        .argv = &.{bin_path},
    }) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "failed to run compiled binary: {s}\n", .{@errorName(err)}) catch "failed to run binary\n";
        std.fs.File.stderr().writeAll(msg) catch {};
        std.process.exit(1);
    };
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);

    // Print program output
    if (run_result.stdout.len > 0) {
        try std.fs.File.stdout().writeAll(run_result.stdout);
    }
    if (run_result.stderr.len > 0) {
        try std.fs.File.stderr().writeAll(run_result.stderr);
    }

    //– Cleanup temp files ──────────────────────────────────────
    // Keep C file and binary for inspection
    // std.fs.cwd().deleteFile(c_path) catch {};
    // std.fs.cwd().deleteFile(bin_path) catch {};

    // Print location of generated files for debugging
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Generated C code: {s}\nCompiled binary: {s}\n", .{ c_path, bin_path }) catch unreachable;
    std.fs.File.stderr().writeAll(msg) catch {};
}
