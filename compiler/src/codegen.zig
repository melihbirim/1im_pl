/// C code generator for 1im.
/// Walks the AST and emits C source code that can be compiled with any C compiler.
const std = @import("std");
const ast = @import("ast.zig");

pub const CodegenError = error{
    UnsupportedNode,
    OutOfMemory,
};

/// Tracks inferred types for variables during codegen.
const ValueType = union(enum) {
    known: ast.Type,
    unknown,
};

pub const Codegen = struct {
    output: std.ArrayList(u8),
    type_defs: std.ArrayList(u8),
    var_types: std.StringHashMap(ValueType),
    fn_returns: std.StringHashMap(?ast.Type),
    error_types: std.StringHashMap([]const u8),
    slice_types: std.StringHashMap([]const u8),
    array_return_types: std.StringHashMap([]const u8),
    emitted_parallel_runner: bool,
    indent_level: usize,
    tmp_counter: usize,
    current_return: ?ast.Type,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Codegen {
        return .{
            .output = .empty,
            .type_defs = .empty,
            .var_types = std.StringHashMap(ValueType).init(allocator),
            .fn_returns = std.StringHashMap(?ast.Type).init(allocator),
            .error_types = std.StringHashMap([]const u8).init(allocator),
            .slice_types = std.StringHashMap([]const u8).init(allocator),
            .array_return_types = std.StringHashMap([]const u8).init(allocator),
            .emitted_parallel_runner = false,
            .indent_level = 1,
            .tmp_counter = 0,
            .current_return = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.output.deinit(self.allocator);
        self.type_defs.deinit(self.allocator);
        self.var_types.deinit();
        self.fn_returns.deinit();
        self.error_types.deinit();
        self.slice_types.deinit();
        self.array_return_types.deinit();
    }

    pub fn generate(self: *Codegen, program: ast.Node) CodegenError![]const u8 {
        const prog = switch (program) {
            .program => |p| p,
            else => return CodegenError.UnsupportedNode,
        };

        // C preamble
        try self.emit("#include <stdio.h>\n");
        try self.emit("#include <stdint.h>\n");
        try self.emit("#include <inttypes.h>\n");
        try self.emit("#include <stdbool.h>\n");
        try self.emit("#include <string.h>\n");
        try self.emit("#include <stddef.h>\n");
        try self.emit("#include <pthread.h>\n");
        try self.emit("\n");

        // Collect function return types (explicit or inferred).
        for (prog.stmts) |stmt| {
            if (stmt != .function_def) continue;
            const fd = stmt.function_def;
            if (fd.return_type) |ret| {
                self.fn_returns.put(fd.name, ret) catch return CodegenError.OutOfMemory;
            } else {
                if (try self.inferFunctionReturnType(fd)) |ret| {
                    self.fn_returns.put(fd.name, ret) catch return CodegenError.OutOfMemory;
                } else {
                    self.fn_returns.put(fd.name, null) catch return CodegenError.OutOfMemory;
                }
            }
        }

        if (self.programHasParallel(prog)) {
            self.emitted_parallel_runner = true;
            try self.emitTo(&self.type_defs, "static void* __1im_par_runner(void* arg) { ");
            try self.emitTo(&self.type_defs, "void (*fn)(void) = *(void (**)(void))arg; ");
            try self.emitTo(&self.type_defs, "fn(); return NULL; }\n");
        }

        try self.collectTypes(prog);
        if (self.type_defs.items.len > 0) {
            try self.emit(self.type_defs.items);
            try self.emit("\n");
        }

        // Emit function declarations first
        for (prog.stmts) |stmt| {
            if (stmt == .function_def) {
                try self.emitFunctionDecl(stmt.function_def);
            }
        }
        try self.emit("\n");

        // Emit function definitions at global scope
        for (prog.stmts) |stmt| {
            if (stmt == .function_def) {
                try self.emitFunctionDef(stmt.function_def);
            }
        }

        // Check if we need a main wrapper
        var has_main = false;
        for (prog.stmts) |stmt| {
            if (stmt == .function_def and std.mem.eql(u8, stmt.function_def.name, "main")) {
                has_main = true;
                break;
            }
        }

        if (!has_main) {
            try self.emit("int main(void) {\n");
        }

        // Emit non-function statements
        for (prog.stmts) |stmt| {
            if (stmt != .function_def) {
                try self.emitStmt(stmt);
            }
        }

        if (!has_main) {
            try self.emit("    return 0;\n");
            try self.emit("}\n");
        }

        return self.output.items;
    }

    fn collectTypes(self: *Codegen, prog: ast.Program) CodegenError!void {
        for (prog.stmts) |stmt| {
            switch (stmt) {
                .typed_assign => |ta| try self.registerType(ta.type_info),
                .function_def => |fd| {
                    for (fd.params) |param| {
                        try self.registerType(param.type_info);
                    }
                    const ret = fd.return_type orelse self.fn_returns.get(fd.name) orelse null;
                    if (ret) |rt| {
                        try self.registerType(rt);
                        if (rt == .array) {
                            _ = try self.arrayReturnTypeName(rt);
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn registerType(self: *Codegen, t: ast.Type) CodegenError!void {
        switch (t) {
            .slice => |s| {
                try self.registerType(s.elem.*);
                _ = try self.sliceTypeName(t);
            },
            .error_union => |eu| {
                try self.registerType(eu.ok.*);
                try self.registerType(eu.err.*);
                _ = try self.errorUnionTypeName(t);
            },
            .array => |arr| try self.registerType(arr.elem.*),
            else => {},
        }
    }

    fn sliceTypeName(self: *Codegen, t: ast.Type) CodegenError![]const u8 {
        const key = try self.typeKey(t);
        if (self.slice_types.get(key)) |name| {
            self.allocator.free(key);
            return name;
        }
        self.slice_types.put(key, key) catch return CodegenError.OutOfMemory;

        try self.emitTo(&self.type_defs, "typedef struct { ");
        const elem = t.slice.elem.*;
        try self.emitTo(&self.type_defs, try self.cTypeName(elem));
        try self.emitTo(&self.type_defs, "* data; size_t len; } ");
        try self.emitTo(&self.type_defs, key);
        try self.emitTo(&self.type_defs, ";\n");

        return key;
    }

    fn errorUnionTypeName(self: *Codegen, t: ast.Type) CodegenError![]const u8 {
        const key = try self.typeKey(t);
        if (self.error_types.get(key)) |name| {
            self.allocator.free(key);
            return name;
        }
        self.error_types.put(key, key) catch return CodegenError.OutOfMemory;

        const eu = t.error_union;
        try self.emitTo(&self.type_defs, "typedef struct { bool ok; ");
        try self.emitTypeDeclTo(&self.type_defs, eu.ok.*, "value");
        try self.emitTo(&self.type_defs, "; ");
        try self.emitTypeDeclTo(&self.type_defs, eu.err.*, "err");
        try self.emitTo(&self.type_defs, "; } ");
        try self.emitTo(&self.type_defs, key);
        try self.emitTo(&self.type_defs, ";\n");

        try self.emitTo(&self.type_defs, "static inline ");
        try self.emitTo(&self.type_defs, key);
        try self.emitTo(&self.type_defs, " ");
        try self.emitTo(&self.type_defs, key);
        try self.emitTo(&self.type_defs, "_ok(");
        try self.emitTypeDeclTo(&self.type_defs, eu.ok.*, "value");
        try self.emitTo(&self.type_defs, ") { return (");
        try self.emitTo(&self.type_defs, key);
        try self.emitTo(&self.type_defs, "){ .ok = true, .value = value, .err = ");
        try self.emitZeroValue(&self.type_defs, eu.err.*);
        try self.emitTo(&self.type_defs, " }; }\n");

        try self.emitTo(&self.type_defs, "static inline ");
        try self.emitTo(&self.type_defs, key);
        try self.emitTo(&self.type_defs, " ");
        try self.emitTo(&self.type_defs, key);
        try self.emitTo(&self.type_defs, "_err(");
        try self.emitTypeDeclTo(&self.type_defs, eu.err.*, "err");
        try self.emitTo(&self.type_defs, ") { return (");
        try self.emitTo(&self.type_defs, key);
        try self.emitTo(&self.type_defs, "){ .ok = false, .value = ");
        try self.emitZeroValue(&self.type_defs, eu.ok.*);
        try self.emitTo(&self.type_defs, ", .err = err }; }\n");

        return key;
    }

    fn arrayReturnTypeName(self: *Codegen, t: ast.Type) CodegenError![]const u8 {
        const key = try self.typeKey(t);
        if (self.array_return_types.get(key)) |name| {
            self.allocator.free(key);
            return name;
        }
        const name = try std.fmt.allocPrint(self.allocator, "arrret_{s}", .{key});
        self.array_return_types.put(key, name) catch return CodegenError.OutOfMemory;

        try self.emitTo(&self.type_defs, "typedef struct { ");
        const base = self.arrayBaseType(t);
        try self.emitTo(&self.type_defs, try self.cTypeName(base));
        try self.emitTo(&self.type_defs, " value");
        try self.emitArrayDimsTo(&self.type_defs, t);
        try self.emitTo(&self.type_defs, "; } ");
        try self.emitTo(&self.type_defs, name);
        try self.emitTo(&self.type_defs, ";\n");

        return name;
    }

    fn typeKey(self: *Codegen, t: ast.Type) CodegenError![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        try self.appendTypeKey(&buf, t);
        return buf.toOwnedSlice(self.allocator) catch return CodegenError.OutOfMemory;
    }

    fn appendTypeKey(self: *Codegen, buf: *std.ArrayList(u8), t: ast.Type) CodegenError!void {
        switch (t) {
            .i8 => try self.emitTo(buf, "i8"),
            .i16 => try self.emitTo(buf, "i16"),
            .i32 => try self.emitTo(buf, "i32"),
            .i64 => try self.emitTo(buf, "i64"),
            .u8 => try self.emitTo(buf, "u8"),
            .u16 => try self.emitTo(buf, "u16"),
            .u32 => try self.emitTo(buf, "u32"),
            .u64 => try self.emitTo(buf, "u64"),
            .f32 => try self.emitTo(buf, "f32"),
            .f64 => try self.emitTo(buf, "f64"),
            .bool => try self.emitTo(buf, "bool"),
            .str => try self.emitTo(buf, "str"),
            .void => try self.emitTo(buf, "void"),
            .slice => |s| {
                try self.emitTo(buf, "slice_");
                try self.appendTypeKey(buf, s.elem.*);
            },
            .error_union => |eu| {
                try self.emitTo(buf, "err_");
                try self.appendTypeKey(buf, eu.ok.*);
                try self.emitTo(buf, "_");
                try self.appendTypeKey(buf, eu.err.*);
            },
            .array => |arr| {
                try self.emitTo(buf, "arr");
                var num: [32]u8 = undefined;
                const len_str = std.fmt.bufPrint(&num, "{d}", .{arr.len}) catch return CodegenError.OutOfMemory;
                try self.emitTo(buf, len_str);
                try self.emitTo(buf, "_");
                try self.appendTypeKey(buf, arr.elem.*);
            },
        }
    }

    fn cTypeName(self: *Codegen, t: ast.Type) CodegenError![]const u8 {
        return switch (t) {
            .slice => blk: {
                const key = try self.typeKey(t);
                defer self.allocator.free(key);
                break :blk self.slice_types.get(key) orelse self.typeToCType(t);
            },
            .error_union => blk: {
                const key = try self.typeKey(t);
                defer self.allocator.free(key);
                break :blk self.error_types.get(key) orelse self.typeToCType(t);
            },
            else => self.typeToCType(t),
        };
    }

    fn cReturnTypeName(self: *Codegen, t: ast.Type) CodegenError![]const u8 {
        return switch (t) {
            .array => try self.arrayReturnTypeName(t),
            else => try self.cTypeName(t),
        };
    }

    fn emitTypeDeclTo(self: *Codegen, out: *std.ArrayList(u8), t: ast.Type, name: []const u8) CodegenError!void {
        switch (t) {
            .array => {
                const base = self.arrayBaseType(t);
                try self.emitTo(out, try self.cTypeName(base));
                try self.emitTo(out, " ");
                try self.emitTo(out, name);
                try self.emitArrayDimsTo(out, t);
            },
            else => {
                try self.emitTo(out, try self.cTypeName(t));
                try self.emitTo(out, " ");
                try self.emitTo(out, name);
            },
        }
    }

    fn emitZeroValue(self: *Codegen, out: *std.ArrayList(u8), t: ast.Type) CodegenError!void {
        switch (t) {
            .str => try self.emitTo(out, "NULL"),
            else => {
                try self.emitTo(out, "(");
                try self.emitTo(out, try self.cTypeName(t));
                try self.emitTo(out, "){0}");
            },
        }
    }

    fn inferFunctionReturnType(self: *Codegen, fd: ast.FunctionDef) CodegenError!?ast.Type {
        var has_value = false;
        var has_void = false;
        var inferred: ast.Type = undefined;

        const PrevVar = struct {
            name: []const u8,
            prev: ?ValueType,
        };
        var prevs: std.ArrayList(PrevVar) = .empty;
        defer {
            for (prevs.items) |item| {
                if (item.prev) |pv| {
                    self.var_types.put(item.name, pv) catch {};
                } else {
                    _ = self.var_types.remove(item.name);
                }
            }
            prevs.deinit(self.allocator);
        }

        // Seed parameter types so return inference can resolve identifiers.
        for (fd.params) |param| {
            try prevs.append(self.allocator, .{ .name = param.name, .prev = self.var_types.get(param.name) });
            self.var_types.put(param.name, .{ .known = param.type_info }) catch return CodegenError.OutOfMemory;
        }

        for (fd.body) |stmt| {
            try self.collectReturnType(stmt, &has_value, &has_void, &inferred);
        }

        if (has_void and has_value) return CodegenError.UnsupportedNode;
        if (has_value) return inferred;
        return null;
    }

    fn collectReturnType(
        self: *Codegen,
        stmt: ast.Node,
        has_value: *bool,
        has_void: *bool,
        inferred: *ast.Type,
    ) CodegenError!void {
        switch (stmt) {
            .return_stmt => |rs| {
                if (rs.value == null) {
                    has_void.* = true;
                    return;
                }

                var ret_type: ast.Type = undefined;
                if (rs.value.?.* == .try_expr) {
                    const inner = self.inferType(rs.value.?.*.try_expr.expr.*);
                    if (inner != .known or inner.known != .error_union) return CodegenError.UnsupportedNode;
                    ret_type = inner.known;
                } else {
                    const value_type = self.inferType(rs.value.?.*);
                    if (value_type != .known) return CodegenError.UnsupportedNode;
                    ret_type = value_type.known;
                }

                if (!has_value.*) {
                    has_value.* = true;
                    inferred.* = ret_type;
                    return;
                }

                if (!self.typeEquals(inferred.*, ret_type)) return CodegenError.UnsupportedNode;
            },
            .if_stmt => |is| {
                for (is.then_body) |s| try self.collectReturnType(s, has_value, has_void, inferred);
                for (is.else_ifs) |elif| {
                    for (elif.body) |s| try self.collectReturnType(s, has_value, has_void, inferred);
                }
                if (is.else_body) |else_body| {
                    for (else_body) |s| try self.collectReturnType(s, has_value, has_void, inferred);
                }
            },
            .while_loop => |wl| for (wl.body) |s| try self.collectReturnType(s, has_value, has_void, inferred),
            .for_loop => |fl| for (fl.body) |s| try self.collectReturnType(s, has_value, has_void, inferred),
            .parallel_block => |pb| for (pb.body) |s| try self.collectReturnType(s, has_value, has_void, inferred),
            .try_catch => |tc| for (tc.catch_body) |s| try self.collectReturnType(s, has_value, has_void, inferred),
            .function_def => {},
            else => {},
        }
    }

    fn emitStmt(self: *Codegen, node: ast.Node) CodegenError!void {
        switch (node) {
            .set_assign => |sa| try self.emitSetAssign(sa),
            .typed_assign => |ta| try self.emitTypedAssign(ta),
            .index_assign => |ia| try self.emitIndexAssign(ia),
            .function_def => |fd| try self.emitFunctionDef(fd),
            .return_stmt => |rs| try self.emitReturn(rs),
            .if_stmt => |is| try self.emitIf(is),
            .while_loop => |wl| try self.emitWhile(wl),
            .for_loop => |fl| try self.emitFor(fl),
            .parallel_block => |pb| try self.emitParallelBlock(pb),
            .break_stmt => try self.emitBreak(),
            .continue_stmt => try self.emitContinue(),
            .try_catch => |tc| try self.emitTryCatch(tc),
            .expr_stmt => |es| try self.emitExprStmt(es),
            else => return CodegenError.UnsupportedNode,
        }
    }

    fn emitSetAssign(self: *Codegen, sa: ast.SetAssign) CodegenError!void {
        if (sa.value.* == .try_expr) {
            return self.emitTryAssign(sa.name, sa.value.*.try_expr, null);
        }
        const val_type = self.inferType(sa.value.*);

        // Check if variable already declared
        const already_declared = self.var_types.contains(sa.name);

        if (!already_declared) {
            // Record variable type
            self.var_types.put(sa.name, val_type) catch return CodegenError.OutOfMemory;

            switch (val_type) {
                .known => |kt| {
                    if (self.isArrayType(kt)) {
                        try self.emitArrayDeclWithValue(kt, sa.name, sa.value.*);
                        return;
                    }
                    // Emit C declaration
                    try self.emitIndent();
                    try self.emit(try self.cTypeName(kt));
                    try self.emit(" ");
                    try self.emit(sa.name);
                    try self.emit(" = ");
                    try self.emitExpr(sa.value.*);
                    try self.emit(";\n");
                },
                .unknown => return CodegenError.UnsupportedNode,
            }
        } else {
            // Emit assignment (variable already declared)
            if (self.var_types.get(sa.name)) |existing| {
                if (existing == .known and existing.known == .array) {
                    return CodegenError.UnsupportedNode;
                }
                if (existing == .known and existing.known == .error_union) {
                    try self.emitIndent();
                    try self.emit(sa.name);
                    try self.emit(" = ");
                    try self.emitErrorUnionValue(existing.known.error_union, sa.value.*);
                    try self.emit(";\n");
                    return;
                }
            }
            try self.emitIndent();
            try self.emit(sa.name);
            try self.emit(" = ");
            try self.emitExpr(sa.value.*);
            try self.emit(";\n");
        }
    }

    fn emitTypedAssign(self: *Codegen, ta: ast.TypedAssign) CodegenError!void {
        const val_type: ValueType = .{ .known = ta.type_info };

        // Check if variable already declared
        const already_declared = self.var_types.contains(ta.name);

        if (!already_declared) {
            // Record variable type
            self.var_types.put(ta.name, val_type) catch return CodegenError.OutOfMemory;

            if (self.isArrayType(ta.type_info)) {
                try self.emitArrayDeclWithValue(ta.type_info, ta.name, ta.value.*);
                return;
            }
            if (self.isSliceType(ta.type_info)) {
                try self.emitSliceDecl(ta.type_info, ta.name, ta.value.*);
                return;
            }
            if (ta.value.* == .try_expr) {
                return self.emitTryAssign(ta.name, ta.value.*.try_expr, ta.type_info);
            }

            // Emit C declaration with explicit type
            try self.emitIndent();
            try self.emit(try self.cTypeName(ta.type_info));
            try self.emit(" ");
            try self.emit(ta.name);
            try self.emit(" = ");
            if (ta.type_info == .error_union) {
                try self.emitErrorUnionValue(ta.type_info.error_union, ta.value.*);
            } else {
                try self.emitExpr(ta.value.*);
            }
            try self.emit(";\n");
        } else {
            // Emit assignment (variable already declared)
            if (ta.value.* == .try_expr) {
                return self.emitTryAssign(ta.name, ta.value.*.try_expr, ta.type_info);
            }
            try self.emitIndent();
            try self.emit(ta.name);
            try self.emit(" = ");
            if (ta.type_info == .error_union) {
                try self.emitErrorUnionValue(ta.type_info.error_union, ta.value.*);
            } else {
                try self.emitExpr(ta.value.*);
            }
            try self.emit(";\n");
        }
    }

    fn emitFunctionDecl(self: *Codegen, fd: ast.FunctionDef) CodegenError!void {
        // Forward declaration
        const ret = fd.return_type orelse self.fn_returns.get(fd.name) orelse null;
        if (ret) |rt| {
            try self.emit(try self.cReturnTypeName(rt));
        } else {
            try self.emit("void");
        }
        try self.emit(" ");
        try self.emit(fd.name);
        try self.emit("(");

        for (fd.params, 0..) |param, i| {
            if (i > 0) try self.emit(", ");
            try self.emitParam(param);
        }

        try self.emit(");\n");
    }

    fn emitFunctionDef(self: *Codegen, fd: ast.FunctionDef) CodegenError!void {
        const prev_return = self.current_return;
        const ret = fd.return_type orelse self.fn_returns.get(fd.name) orelse null;
        self.current_return = ret;
        defer self.current_return = prev_return;

        const prev_var_types = self.var_types;
        self.var_types = std.StringHashMap(ValueType).init(self.allocator);
        defer {
            self.var_types.deinit();
            self.var_types = prev_var_types;
        }

        // Record parameter types
        for (fd.params) |param| {
            const ptype: ValueType = .{ .known = param.type_info };
            self.var_types.put(param.name, ptype) catch return CodegenError.OutOfMemory;
        }

        // Function signature
        if (ret) |rt| {
            try self.emit(try self.cReturnTypeName(rt));
        } else {
            try self.emit("void");
        }
        try self.emit(" ");
        try self.emit(fd.name);
        try self.emit("(");

        for (fd.params, 0..) |param, i| {
            if (i > 0) try self.emit(", ");
            try self.emitParam(param);
        }

        try self.emit(") {\n");

        self.indent_level += 1;

        // Emit body
        for (fd.body) |stmt| {
            try self.emitStmt(stmt);
        }

        self.indent_level -= 1;
        try self.emit("}\n\n");
    }

    fn emitParam(self: *Codegen, param: ast.Param) CodegenError!void {
        switch (param.type_info) {
            .array => {
                const base = self.arrayBaseType(param.type_info);
                try self.emit(try self.cTypeName(base));
                try self.emit(" ");
                try self.emit(param.name);
                try self.emitArrayDims(param.type_info);
            },
            else => {
                try self.emit(try self.cTypeName(param.type_info));
                try self.emit(" ");
                try self.emit(param.name);
            },
        }
    }

    fn emitReturn(self: *Codegen, rs: ast.ReturnStmt) CodegenError!void {
        const ret_type = self.current_return;

        if (ret_type == null) {
            try self.emitIndent();
            try self.emit("return;\n");
            return;
        }

        const expected = ret_type.?;
        if (rs.value != null and rs.value.?.* == .try_expr) {
            if (expected != .error_union) return CodegenError.UnsupportedNode;
            return self.emitTryReturn(rs.value.?.*.try_expr, expected.error_union);
        }
        try self.emitIndent();
        if (expected == .array) {
            if (rs.value == null) return CodegenError.UnsupportedNode;
            const name = try self.arrayReturnTypeName(expected);
            const val = rs.value.?.*;
            switch (val) {
                .array_literal => |lit| {
                    try self.emit("return (");
                    try self.emit(name);
                    try self.emit("){ .value = ");
                    try self.emitArrayLiteral(lit);
                    try self.emit(" };\n");
                },
                else => {
                    const tmp = try self.nextTmpName("ret");
                    try self.emit(name);
                    try self.emit(" ");
                    try self.emit(tmp);
                    try self.emit(";\n");
                    try self.emitIndent();
                    try self.emit("memcpy(");
                    try self.emit(tmp);
                    try self.emit(".value, ");
                    try self.emitExpr(val);
                    try self.emit(", sizeof(");
                    try self.emit(tmp);
                    try self.emit(".value));\n");
                    try self.emitIndent();
                    try self.emit("return ");
                    try self.emit(tmp);
                    try self.emit(";\n");
                },
            }
            return;
        }

        if (expected == .error_union) {
            if (rs.value == null) return CodegenError.UnsupportedNode;
            try self.emit("return ");
            try self.emitErrorUnionValue(expected.error_union, rs.value.?.*);
            try self.emit(";\n");
            return;
        }

        try self.emit("return");
        if (rs.value) |val| {
            try self.emit(" ");
            try self.emitExpr(val.*);
        }
        try self.emit(";\n");
    }

    fn emitTryAssign(self: *Codegen, name: []const u8, te: ast.TryExpr, explicit_type: ?ast.Type) CodegenError!void {
        const inner_type = self.inferType(te.expr.*);
        if (inner_type != .known or inner_type.known != .error_union) {
            return CodegenError.UnsupportedNode;
        }
        const eu = inner_type.known.error_union;
        const ok_type = eu.ok.*;

        const ret_type = self.current_return orelse return CodegenError.UnsupportedNode;
        if (ret_type != .error_union) return CodegenError.UnsupportedNode;
        const ret_name = try self.errorUnionTypeName(ret_type);

        if (explicit_type) |t| {
            if (t != .error_union and !self.typeEquals(t, ok_type)) {
                return CodegenError.UnsupportedNode;
            }
        }

        const declare = !self.var_types.contains(name);
        if (declare) {
            const store_type = explicit_type orelse ok_type;
            self.var_types.put(name, .{ .known = store_type }) catch return CodegenError.OutOfMemory;
        }

        const tmp = try self.nextTmpName("try");
        try self.emitIndent();
        try self.emit(try self.cTypeName(inner_type.known));
        try self.emit(" ");
        try self.emit(tmp);
        try self.emit(" = ");
        try self.emitExpr(te.expr.*);
        try self.emit(";\n");

        try self.emitIndent();
        try self.emit("if (!");
        try self.emit(tmp);
        try self.emit(".ok) return ");
        try self.emit(ret_name);
        try self.emit("_err(");
        try self.emit(tmp);
        try self.emit(".err);\n");

        try self.emitIndent();
        if (declare) {
            const store_type = explicit_type orelse ok_type;
            try self.emit(try self.cTypeName(store_type));
            try self.emit(" ");
            try self.emit(name);
            try self.emit(" = ");
        } else {
            try self.emit(name);
            try self.emit(" = ");
        }

        if (explicit_type) |t| {
            if (t == .error_union) {
                const name_type = try self.errorUnionTypeName(t);
                try self.emit(name_type);
                try self.emit("_ok(");
                try self.emit(tmp);
                try self.emit(".value)");
                try self.emit(";\n");
                return;
            }
        }

        try self.emit(tmp);
        try self.emit(".value;\n");
    }

    fn emitTryExprStmt(self: *Codegen, te: ast.TryExpr) CodegenError!void {
        const inner_type = self.inferType(te.expr.*);
        if (inner_type != .known or inner_type.known != .error_union) {
            return CodegenError.UnsupportedNode;
        }
        const ret_type = self.current_return orelse return CodegenError.UnsupportedNode;
        if (ret_type != .error_union) return CodegenError.UnsupportedNode;
        const ret_name = try self.errorUnionTypeName(ret_type);

        const tmp = try self.nextTmpName("try");
        try self.emitIndent();
        try self.emit(try self.cTypeName(inner_type.known));
        try self.emit(" ");
        try self.emit(tmp);
        try self.emit(" = ");
        try self.emitExpr(te.expr.*);
        try self.emit(";\n");

        try self.emitIndent();
        try self.emit("if (!");
        try self.emit(tmp);
        try self.emit(".ok) return ");
        try self.emit(ret_name);
        try self.emit("_err(");
        try self.emit(tmp);
        try self.emit(".err);\n");
    }

    fn emitTryReturn(self: *Codegen, te: ast.TryExpr, ret_eu: ast.ErrorUnionType) CodegenError!void {
        const inner_type = self.inferType(te.expr.*);
        if (inner_type != .known or inner_type.known != .error_union) {
            return CodegenError.UnsupportedNode;
        }

        const ret_name = try self.errorUnionTypeName(.{ .error_union = ret_eu });

        const tmp = try self.nextTmpName("try");
        try self.emitIndent();
        try self.emit(try self.cTypeName(inner_type.known));
        try self.emit(" ");
        try self.emit(tmp);
        try self.emit(" = ");
        try self.emitExpr(te.expr.*);
        try self.emit(";\n");

        try self.emitIndent();
        try self.emit("if (!");
        try self.emit(tmp);
        try self.emit(".ok) return ");
        try self.emit(ret_name);
        try self.emit("_err(");
        try self.emit(tmp);
        try self.emit(".err);\n");

        try self.emitIndent();
        try self.emit("return ");
        try self.emit(ret_name);
        try self.emit("_ok(");
        try self.emit(tmp);
        try self.emit(".value);\n");
    }

    fn emitErrorUnionValue(self: *Codegen, eu: ast.ErrorUnionType, value: ast.Node) CodegenError!void {
        const eu_type = ast.Type{ .error_union = eu };
        const name = try self.errorUnionTypeName(eu_type);
        const val_type = self.inferType(value);

        if (val_type == .known and val_type.known == .error_union and self.typeEquals(val_type.known, eu_type)) {
            try self.emitExpr(value);
            return;
        }

        if (self.valueMatchesType(value, eu.ok.*)) {
            try self.emit(name);
            try self.emit("_ok(");
            try self.emitExpr(value);
            try self.emit(")");
            return;
        }

        if (self.valueMatchesType(value, eu.err.*)) {
            try self.emit(name);
            try self.emit("_err(");
            try self.emitExpr(value);
            try self.emit(")");
            return;
        }

        return CodegenError.UnsupportedNode;
    }

    fn valueMatchesType(self: *Codegen, value: ast.Node, t: ast.Type) bool {
        const vt = self.inferType(value);
        if (vt == .known) {
            return self.typeEquals(vt.known, t);
        }
        return switch (value) {
            .null_literal => self.typeEquals(t, .str),
            else => false,
        };
    }

    fn nextTmpName(self: *Codegen, prefix: []const u8) CodegenError![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "__{s}{d}", .{ prefix, self.tmp_counter });
        self.tmp_counter += 1;
        return name;
    }

    fn emitIf(self: *Codegen, is: ast.IfStmt) CodegenError!void {
        try self.emitIndent();
        try self.emit("if (");
        try self.emitExpr(is.condition.*);
        try self.emit(") {\n");

        self.indent_level += 1;
        for (is.then_body) |stmt| {
            try self.emitStmt(stmt);
        }
        self.indent_level -= 1;

        // else if clauses
        for (is.else_ifs) |elif| {
            try self.emitIndent();
            try self.emit("} else if (");
            try self.emitExpr(elif.condition.*);
            try self.emit(") {\n");

            self.indent_level += 1;
            for (elif.body) |stmt| {
                try self.emitStmt(stmt);
            }
            self.indent_level -= 1;
        }

        // else clause
        if (is.else_body) |else_body| {
            try self.emitIndent();
            try self.emit("} else {\n");

            self.indent_level += 1;
            for (else_body) |stmt| {
                try self.emitStmt(stmt);
            }
            self.indent_level -= 1;
        }

        try self.emitIndent();
        try self.emit("}\n");
    }

    fn emitWhile(self: *Codegen, wl: ast.WhileLoop) CodegenError!void {
        if (wl.parallel) return CodegenError.UnsupportedNode;
        try self.emitIndent();
        try self.emit("while (");
        try self.emitExpr(wl.condition.*);
        try self.emit(") {\n");

        self.indent_level += 1;
        for (wl.body) |stmt| {
            try self.emitStmt(stmt);
        }
        self.indent_level -= 1;

        try self.emitIndent();
        try self.emit("}\n");
    }

    fn emitFor(self: *Codegen, fl: ast.ForLoop) CodegenError!void {
        switch (fl.iterable.*) {
            .range => |range| {
                const start_type = self.inferType(range.start.*);
                const end_type = self.inferType(range.end.*);
                const loop_type: ast.Type = blk: {
                    if (start_type == .known and (start_type.known == .i64 or start_type.known == .u64)) break :blk .i64;
                    if (end_type == .known and (end_type.known == .i64 or end_type.known == .u64)) break :blk .i64;
                    break :blk .i32;
                };

                const prev = self.var_types.get(fl.variable);
                const had_prev = prev != null;
                self.var_types.put(fl.variable, .{ .known = loop_type }) catch return CodegenError.OutOfMemory;
                defer {
                    if (had_prev) {
                        self.var_types.put(fl.variable, prev.?) catch {};
                    } else {
                        _ = self.var_types.remove(fl.variable);
                    }
                }

                if (fl.parallel) {
                    try self.emitIndent();
                    try self.emit("#pragma omp parallel for\n");
                }
                try self.emitIndent();
                try self.emit("for (");
                try self.emit(self.typeToCType(loop_type));
                try self.emit(" ");
                try self.emit(fl.variable);
                try self.emit(" = ");
                try self.emitExpr(range.start.*);
                try self.emit("; ");
                try self.emit(fl.variable);
                try self.emit(if (range.inclusive) " <= " else " < ");
                try self.emitExpr(range.end.*);
                try self.emit("; ");
                try self.emit(fl.variable);
                try self.emit("++) {\n");

                self.indent_level += 1;
                for (fl.body) |stmt| {
                    try self.emitStmt(stmt);
                }
                self.indent_level -= 1;

                try self.emitIndent();
                try self.emit("}\n");
            },
            else => {
                const iter_type = self.inferType(fl.iterable.*);
                if (iter_type != .known) return CodegenError.UnsupportedNode;

                var elem_type: ast.Type = undefined;
                var use_slice = false;
                switch (iter_type.known) {
                    .array => |arr| elem_type = arr.elem.*,
                    .slice => |s| {
                        elem_type = s.elem.*;
                        use_slice = true;
                    },
                    else => return CodegenError.UnsupportedNode,
                }

                const prev = self.var_types.get(fl.variable);
                const had_prev = prev != null;
                self.var_types.put(fl.variable, .{ .known = elem_type }) catch return CodegenError.OutOfMemory;
                defer {
                    if (had_prev) {
                        self.var_types.put(fl.variable, prev.?) catch {};
                    } else {
                        _ = self.var_types.remove(fl.variable);
                    }
                }

                const idx = try self.nextTmpName("i");
                const iter_tmp = try self.nextTmpName("iter");

                try self.emitIndent();
                try self.emit("{\n");
                self.indent_level += 1;

                if (use_slice) {
                    try self.emitIndent();
                    try self.emit(try self.cTypeName(iter_type.known));
                    try self.emit(" ");
                    try self.emit(iter_tmp);
                    try self.emit(" = ");
                    try self.emitExpr(fl.iterable.*);
                    try self.emit(";\n");
                }

                if (fl.parallel) {
                    try self.emitIndent();
                    try self.emit("#pragma omp parallel for\n");
                }
                try self.emitIndent();
                try self.emit("for (size_t ");
                try self.emit(idx);
                try self.emit(" = 0; ");
                try self.emit(idx);
                try self.emit(" < ");
                if (use_slice) {
                    try self.emit(iter_tmp);
                    try self.emit(".len");
                } else {
                    switch (iter_type.known) {
                        .array => |arr| {
                            var buf: [32]u8 = undefined;
                            const s = std.fmt.bufPrint(&buf, "{d}", .{arr.len}) catch return CodegenError.OutOfMemory;
                            try self.emit(s);
                        },
                        else => return CodegenError.UnsupportedNode,
                    }
                }
                try self.emit("; ");
                try self.emit(idx);
                try self.emit("++) {\n");

                self.indent_level += 1;
                try self.emitIndent();
                try self.emit(try self.cTypeName(elem_type));
                try self.emit(" ");
                try self.emit(fl.variable);
                try self.emit(" = ");
                if (use_slice) {
                    try self.emit(iter_tmp);
                    try self.emit(".data[");
                } else {
                    try self.emitExpr(fl.iterable.*);
                    try self.emit("[");
                }
                try self.emit(idx);
                try self.emit("];\n");

                for (fl.body) |stmt| {
                    try self.emitStmt(stmt);
                }
                self.indent_level -= 1;
                try self.emitIndent();
                try self.emit("}\n");

                self.indent_level -= 1;
                try self.emitIndent();
                try self.emit("}\n");
            },
        }
    }

    fn emitParallelBlock(self: *Codegen, pb: ast.ParallelBlock) CodegenError!void {
        const thread_name = try self.nextTmpName("par_threads");
        const fn_name = try self.nextTmpName("par_fns");

        const count = pb.body.len;
        try self.emitIndent();
        try self.emit("pthread_t ");
        try self.emit(thread_name);
        try self.emit("[");
        try self.emitInt(count);
        try self.emit("];\n");

        try self.emitIndent();
        try self.emit("void (*");
        try self.emit(fn_name);
        try self.emit("[");
        try self.emitInt(count);
        try self.emit("])(void) = { ");

        for (pb.body, 0..) |stmt, i| {
            if (i > 0) try self.emit(", ");
            const callee = switch (stmt) {
                .expr_stmt => |es| switch (es.expr.*) {
                    .call => |c| blk: {
                        if (c.args.len != 0) return CodegenError.UnsupportedNode;
                        break :blk c.callee;
                    },
                    else => return CodegenError.UnsupportedNode,
                },
                else => return CodegenError.UnsupportedNode,
            };
            try self.emit("(void (*)(void))");
            try self.emit(callee);
        }
        try self.emit(" };\n");

        // Spawn threads
        for (pb.body, 0..) |_, i| {
            try self.emitIndent();
            try self.emit("pthread_create(&");
            try self.emit(thread_name);
            try self.emit("[");
            try self.emitInt(i);
            try self.emit("], NULL, __1im_par_runner, (void*)&");
            try self.emit(fn_name);
            try self.emit("[");
            try self.emitInt(i);
            try self.emit("]);\n");
        }

        // Join threads
        for (pb.body, 0..) |_, i| {
            try self.emitIndent();
            try self.emit("pthread_join(");
            try self.emit(thread_name);
            try self.emit("[");
            try self.emitInt(i);
            try self.emit("], NULL);\n");
        }
    }

    fn programHasParallel(self: *Codegen, prog: ast.Program) bool {
        for (prog.stmts) |stmt| {
            if (self.nodeHasParallel(stmt)) return true;
        }
        return false;
    }

    fn nodeHasParallel(self: *Codegen, node: ast.Node) bool {
        return switch (node) {
            .parallel_block => true,
            .if_stmt => |is| blk: {
                for (is.then_body) |s| if (self.nodeHasParallel(s)) break :blk true;
                for (is.else_ifs) |elif| {
                    for (elif.body) |s| if (self.nodeHasParallel(s)) break :blk true;
                }
                if (is.else_body) |else_body| {
                    for (else_body) |s| if (self.nodeHasParallel(s)) break :blk true;
                }
                break :blk false;
            },
            .while_loop => |wl| {
                for (wl.body) |s| if (self.nodeHasParallel(s)) return true;
                return false;
            },
            .for_loop => |fl| {
                for (fl.body) |s| if (self.nodeHasParallel(s)) return true;
                return false;
            },
            .try_catch => |tc| {
                for (tc.catch_body) |s| if (self.nodeHasParallel(s)) return true;
                return false;
            },
            .function_def => |fd| {
                for (fd.body) |s| if (self.nodeHasParallel(s)) return true;
                return false;
            },
            else => false,
        };
    }

    fn emitInt(self: *Codegen, value: usize) CodegenError!void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return CodegenError.OutOfMemory;
        try self.emit(s);
    }

    fn emitBreak(self: *Codegen) CodegenError!void {
        try self.emitIndent();
        try self.emit("break;\n");
    }

    fn emitContinue(self: *Codegen) CodegenError!void {
        try self.emitIndent();
        try self.emit("continue;\n");
    }

    fn emitTryCatch(self: *Codegen, tc: ast.TryCatch) CodegenError!void {
        const try_type = self.inferType(tc.try_expr.*);
        if (try_type != .known or try_type.known != .error_union) {
            return CodegenError.UnsupportedNode;
        }
        const eu = try_type.known.error_union;

        const tmp = try self.nextTmpName("try");
        try self.emitIndent();
        try self.emit("{\n");
        self.indent_level += 1;

        try self.emitIndent();
        try self.emit(try self.cTypeName(try_type.known));
        try self.emit(" ");
        try self.emit(tmp);
        try self.emit(" = ");
        try self.emitExpr(tc.try_expr.*);
        try self.emit(";\n");

        try self.emitIndent();
        try self.emit("if (!");
        try self.emit(tmp);
        try self.emit(".ok) {\n");
        self.indent_level += 1;

        var had_prev = false;
        var prev: ?ValueType = null;
        if (tc.catch_var) |name| {
            prev = self.var_types.get(name);
            had_prev = prev != null;
            self.var_types.put(name, .{ .known = eu.err.* }) catch return CodegenError.OutOfMemory;

            try self.emitIndent();
            try self.emit(try self.cTypeName(eu.err.*));
            try self.emit(" ");
            try self.emit(name);
            try self.emit(" = ");
            try self.emit(tmp);
            try self.emit(".err;\n");
        }

        for (tc.catch_body) |stmt| {
            try self.emitStmt(stmt);
        }

        if (tc.catch_var) |name| {
            if (had_prev) {
                self.var_types.put(name, prev.?) catch {};
            } else {
                _ = self.var_types.remove(name);
            }
        }

        self.indent_level -= 1;
        try self.emitIndent();
        try self.emit("}\n");

        self.indent_level -= 1;
        try self.emitIndent();
        try self.emit("}\n");
    }

    fn emitExprStmt(self: *Codegen, es: ast.ExprStmt) CodegenError!void {
        switch (es.expr.*) {
            .call => |c| try self.emitCall(c),
            .try_expr => |te| try self.emitTryExprStmt(te),
            else => {
                try self.emitIndent();
                try self.emitExpr(es.expr.*);
                try self.emit(";\n");
            },
        }
    }

    fn emitCall(self: *Codegen, call: ast.Call) CodegenError!void {
        if (std.mem.eql(u8, call.callee, "print")) {
            try self.emitPrint(call);
        } else if (std.mem.eql(u8, call.callee, "len")) {
            return CodegenError.UnsupportedNode;
        } else {
            // Generic function call
            try self.emitIndent();
            try self.emit(call.callee);
            try self.emit("(");
            for (call.args, 0..) |arg, i| {
                if (i > 0) try self.emit(", ");
                try self.emitExpr(arg);
            }
            try self.emit(");\n");
        }
    }

    fn emitPrint(self: *Codegen, call: ast.Call) CodegenError!void {
        if (call.args.len == 0) {
            try self.emitIndent();
            try self.emit("printf(\"\\\");");
            return;
        }

        // Single argument print
        const arg = call.args[0];
        const arg_type = self.inferType(arg);

        try self.emitIndent();
        switch (arg_type) {
            .known => |kt| switch (kt) {
                .i8, .i16, .i32 => {
                    try self.emit("printf(\"%d\\n\", (int)");
                    try self.emitExpr(arg);
                    try self.emit(");\n");
                },
                .i64 => {
                    try self.emit("printf(\"%\" PRId64 \"\\n\", (int64_t)");
                    try self.emitExpr(arg);
                    try self.emit(");\n");
                },
                .u8, .u16, .u32 => {
                    try self.emit("printf(\"%u\\n\", (unsigned int)");
                    try self.emitExpr(arg);
                    try self.emit(");\n");
                },
                .u64 => {
                    try self.emit("printf(\"%\" PRIu64 \"\\n\", (uint64_t)");
                    try self.emitExpr(arg);
                    try self.emit(");\n");
                },
                .f32 => {
                    try self.emit("printf(\"%f\\n\", (float)");
                    try self.emitExpr(arg);
                    try self.emit(");\n");
                },
                .f64 => {
                    try self.emit("printf(\"%f\\n\", (double)");
                    try self.emitExpr(arg);
                    try self.emit(");\n");
                },
                .bool => {
                    try self.emit("printf(\"%s\\n\", ");
                    try self.emitExpr(arg);
                    try self.emit(" ? \"true\" : \"false\");\n");
                },
                .str => {
                    try self.emit("printf(\"%s\\n\", ");
                    try self.emitExpr(arg);
                    try self.emit(");\n");
                },
                .array, .slice, .error_union => return CodegenError.UnsupportedNode,
                .void => return CodegenError.UnsupportedNode,
            },
            .unknown => {
                // Default: try as integer
                try self.emit("printf(\"%\" PRId64 \"\\n\", (int64_t)");
                try self.emitExpr(arg);
                try self.emit(");\n");
            },
        }
    }

    fn emitArrayDecl(self: *Codegen, t: ast.Type, name: []const u8, value: ast.Node) CodegenError!void {
        switch (t) {
            .array => {},
            else => return CodegenError.UnsupportedNode,
        }

        try self.emitIndent();
        const base_type = self.arrayBaseType(t);
        try self.emit(try self.cTypeName(base_type));
        try self.emit(" ");
        try self.emit(name);
        try self.emitArrayDims(t);
        try self.emit(" = ");

        switch (value) {
            .array_literal => |lit| try self.emitArrayLiteral(lit),
            else => return CodegenError.UnsupportedNode,
        }

        try self.emit(";\n");
    }

    fn emitArrayDeclWithValue(self: *Codegen, t: ast.Type, name: []const u8, value: ast.Node) CodegenError!void {
        switch (value) {
            .array_literal => {
                try self.emitArrayDecl(t, name, value);
                return;
            },
            else => {},
        }

        // Declare without initializer, then memcpy from source expression.
        try self.emitIndent();
        const base_type = self.arrayBaseType(t);
        try self.emit(try self.cTypeName(base_type));
        try self.emit(" ");
        try self.emit(name);
        try self.emitArrayDims(t);
        try self.emit(";\n");

        try self.emitIndent();
        try self.emit("memcpy(");
        try self.emit(name);
        try self.emit(", ");
        try self.emitExpr(value);
        try self.emit(", sizeof(");
        try self.emit(name);
        try self.emit("));\n");
    }

    fn emitArrayLiteral(self: *Codegen, lit: ast.ArrayLiteral) CodegenError!void {
        try self.emit("{");
        for (lit.elements, 0..) |elem, i| {
            if (i > 0) try self.emit(", ");
            switch (elem) {
                .array_literal => |inner| try self.emitArrayLiteral(inner),
                else => try self.emitExpr(elem),
            }
        }
        try self.emit("}");
    }

    fn emitSliceDecl(self: *Codegen, t: ast.Type, name: []const u8, value: ast.Node) CodegenError!void {
        const slice = switch (t) {
            .slice => |s| s,
            else => return CodegenError.UnsupportedNode,
        };

        const value_type = self.inferType(value);
        if (value_type == .known and value_type.known == .slice) {
            try self.emitIndent();
            try self.emit(try self.cTypeName(t));
            try self.emit(" ");
            try self.emit(name);
            try self.emit(" = ");
            try self.emitExpr(value);
            try self.emit(";\n");
            return;
        }

        const data_name = try std.fmt.allocPrint(self.allocator, "{s}_data", .{name});
        defer self.allocator.free(data_name);

        const arr_type = ast.Type{ .array = .{ .len = switch (value) {
            .array_literal => |lit| lit.elements.len,
            else => blk: {
                if (value_type == .known and value_type.known == .array) {
                    break :blk value_type.known.array.len;
                }
                return CodegenError.UnsupportedNode;
            },
        }, .elem = slice.elem } };

        if (value == .array_literal) {
            try self.emitArrayDecl(arr_type, data_name, value);
        } else if (value_type == .known and value_type.known == .array) {
            try self.emitIndent();
            const base_type = self.arrayBaseType(value_type.known);
            try self.emit(try self.cTypeName(base_type));
            try self.emit(" ");
            try self.emit(data_name);
            try self.emitArrayDims(value_type.known);
            try self.emit(";\n");

            try self.emitIndent();
            try self.emit("memcpy(");
            try self.emit(data_name);
            try self.emit(", ");
            try self.emitExpr(value);
            try self.emit(", sizeof(");
            try self.emit(data_name);
            try self.emit("));\n");
        } else {
            return CodegenError.UnsupportedNode;
        }

        try self.emitIndent();
        try self.emit(try self.cTypeName(t));
        try self.emit(" ");
        try self.emit(name);
        try self.emit(" = { ");
        try self.emit(data_name);
        try self.emit(", ");
        var buf: [32]u8 = undefined;
        const len_str = std.fmt.bufPrint(&buf, "{d}", .{arr_type.array.len}) catch return CodegenError.OutOfMemory;
        try self.emit(len_str);
        try self.emit(" };\n");
    }

    fn emitIndexAssign(self: *Codegen, ia: ast.IndexAssign) CodegenError!void {
        try self.emitIndent();
        switch (ia.target.*) {
            .index_expr => |ix| try self.emitIndexExpr(ix),
            else => return CodegenError.UnsupportedNode,
        }
        try self.emit(" = ");
        try self.emitExpr(ia.value.*);
        try self.emit(";\n");
    }

    fn emitIndexExpr(self: *Codegen, ix: ast.IndexExpr) CodegenError!void {
        const target_type = self.inferType(ix.target.*);
        if (target_type == .known and target_type.known == .slice) {
            try self.emitExpr(ix.target.*);
            try self.emit(".data[");
            try self.emitExpr(ix.index.*);
            try self.emit("]");
            return;
        }
        try self.emitExpr(ix.target.*);
        try self.emit("[");
        try self.emitExpr(ix.index.*);
        try self.emit("]");
    }

    fn emitLenExpr(self: *Codegen, call: ast.Call) CodegenError!void {
        if (call.args.len != 1) return CodegenError.UnsupportedNode;
        const arg = call.args[0];
        const arg_type = self.inferType(arg);
        if (arg_type != .known) return CodegenError.UnsupportedNode;

        switch (arg_type.known) {
            .array => |arr| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{arr.len}) catch return CodegenError.OutOfMemory;
                try self.emit(s);
            },
            .slice => {
                try self.emitExpr(arg);
                try self.emit(".len");
            },
            else => return CodegenError.UnsupportedNode,
        }
    }

    fn emitArrayDims(self: *Codegen, t: ast.Type) CodegenError!void {
        try self.emitArrayDimsTo(&self.output, t);
    }

    fn arrayBaseType(self: *Codegen, t: ast.Type) ast.Type {
        return switch (t) {
            .array => |arr| self.arrayBaseType(arr.elem.*),
            else => t,
        };
    }

    fn emitExpr(self: *Codegen, node: ast.Node) CodegenError!void {
        switch (node) {
            .int_literal => |lit| {
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{lit.value}) catch return CodegenError.OutOfMemory;
                try self.emit(s);
            },
            .float_literal => |lit| {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{lit.value}) catch return CodegenError.OutOfMemory;
                try self.emit(s);
            },
            .string_literal => |lit| {
                try self.emit("\"");
                try self.emit(lit.value);
                try self.emit("\"");
            },
            .bool_literal => |lit| {
                try self.emit(if (lit.value) "true" else "false");
            },
            .null_literal => {
                try self.emit("NULL");
            },
            .variable => |v| {
                try self.emit(v.name);
            },
            .binary_op => |bin| {
                try self.emit("(");
                try self.emitExpr(bin.left.*);
                switch (bin.op) {
                    .add => try self.emit(" + "),
                    .sub => try self.emit(" - "),
                    .mul => try self.emit(" * "),
                    .div => try self.emit(" / "),
                    .mod => try self.emit(" % "),
                    .eq => try self.emit(" == "),
                    .neq => try self.emit(" != "),
                    .lt => try self.emit(" < "),
                    .lte => try self.emit(" <= "),
                    .gt => try self.emit(" > "),
                    .gte => try self.emit(" >= "),
                    .bool_and => try self.emit(" && "),
                    .bool_or => try self.emit(" || "),
                }
                try self.emitExpr(bin.right.*);
                try self.emit(")");
            },
            .unary_op => |un| {
                switch (un.op) {
                    .negate => try self.emit("(-"),
                    .bool_not => try self.emit("(!"),
                }
                try self.emitExpr(un.operand.*);
                try self.emit(")");
            },
            .call => |c| {
                if (std.mem.eql(u8, c.callee, "len")) {
                    try self.emitLenExpr(c);
                } else {
                    const ret_type = self.fn_returns.get(c.callee);
                    const wraps_array = if (ret_type) |rt| blk: {
                        if (rt) |inner| break :blk inner == .array;
                        break :blk false;
                    } else false;
                    if (wraps_array) try self.emit("(");
                    try self.emit(c.callee);
                    try self.emit("(");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) try self.emit(", ");
                        try self.emitExpr(arg);
                    }
                    try self.emit(")");
                    if (wraps_array) try self.emit(").value");
                }
            },
            .array_literal => |lit| try self.emitArrayLiteral(lit),
            .index_expr => |ix| try self.emitIndexExpr(ix),
            .try_expr => return CodegenError.UnsupportedNode,
            .range => return CodegenError.UnsupportedNode,
            else => return CodegenError.UnsupportedNode,
        }
    }

    // ── Type inference (minimal) ────────────────────────────────

    fn inferType(self: *Codegen, node: ast.Node) ValueType {
        return switch (node) {
            .int_literal => .{ .known = .i32 },
            .float_literal => .{ .known = .f64 },
            .string_literal => .{ .known = .str },
            .bool_literal => .{ .known = .bool },
            .null_literal => .unknown,
            .variable => |v| self.var_types.get(v.name) orelse .unknown,
            .binary_op => |bin| {
                const lt = self.inferType(bin.left.*);
                const rt = self.inferType(bin.right.*);
                if (lt == .known and rt == .known) {
                    if (self.isFloatType(lt.known) or self.isFloatType(rt.known)) {
                        if (self.isFloatType(lt.known)) return lt;
                        return rt;
                    }
                    if (self.isInt64(lt.known) or self.isInt64(rt.known)) return lt;
                    return lt;
                }
                return .unknown;
            },
            .unary_op => |un| self.inferType(un.operand.*),
            .call => |c| blk: {
                if (std.mem.eql(u8, c.callee, "len")) break :blk .{ .known = .i32 };
                if (self.fn_returns.get(c.callee)) |ret_opt| {
                    if (ret_opt) |ret_type| {
                        break :blk .{ .known = ret_type };
                    }
                    break :blk .{ .known = .void };
                }
                break :blk .unknown;
            },
            .array_literal => |lit| self.inferArrayLiteralType(lit),
            .index_expr => |ix| {
                const target_t = self.inferType(ix.target.*);
                if (target_t == .known) {
                    switch (target_t.known) {
                        .array => |arr| return .{ .known = arr.elem.* },
                        .slice => |s| return .{ .known = s.elem.* },
                        else => return .unknown,
                    }
                }
                return .unknown;
            },
            .try_expr => |te| {
                const inner = self.inferType(te.expr.*);
                if (inner == .known and inner.known == .error_union) {
                    return .{ .known = inner.known.error_union.ok.* };
                }
                return .unknown;
            },
            else => .unknown,
        };
    }

    fn inferArrayLiteralType(self: *Codegen, lit: ast.ArrayLiteral) ValueType {
        if (lit.elements.len == 0) return .unknown;
        const first = self.inferType(lit.elements[0]);
        if (first != .known) return .unknown;
        const elem_type = first.known;
        for (lit.elements[1..]) |elem| {
            const t = self.inferType(elem);
            if (t != .known or !self.typeEquals(t.known, elem_type)) {
                return .unknown;
            }
        }
        const elem_ptr = self.allocType(elem_type) catch return .unknown;
        return .{ .known = .{ .array = .{ .len = lit.elements.len, .elem = elem_ptr } } };
    }

    fn isFloatType(self: *const Codegen, t: ast.Type) bool {
        _ = self;
        return t == .f32 or t == .f64;
    }

    fn isInt64(self: *const Codegen, t: ast.Type) bool {
        _ = self;
        return t == .i64 or t == .u64;
    }

    fn isArrayType(self: *const Codegen, t: ast.Type) bool {
        _ = self;
        return t == .array;
    }

    fn isSliceType(self: *const Codegen, t: ast.Type) bool {
        _ = self;
        return t == .slice;
    }

    fn typeToCType(self: *const Codegen, t: ast.Type) []const u8 {
        _ = self;
        return switch (t) {
            .i8 => "int8_t",
            .i16 => "int16_t",
            .i32 => "int32_t",
            .i64 => "int64_t",
            .u8 => "uint8_t",
            .u16 => "uint16_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .f32 => "float",
            .f64 => "double",
            .bool => "bool",
            .str => "const char*",
            .error_union => "void",
            else => "int64_t",
        };
    }

    fn allocType(self: *Codegen, t: ast.Type) CodegenError!*ast.Type {
        const t_ptr = self.allocator.create(ast.Type) catch return CodegenError.OutOfMemory;
        t_ptr.* = t;
        return t_ptr;
    }

    fn typeEquals(self: *Codegen, a: ast.Type, b: ast.Type) bool {
        return switch (a) {
            .error_union => |eu| switch (b) {
                .error_union => |beu| self.typeEquals(eu.ok.*, beu.ok.*) and self.typeEquals(eu.err.*, beu.err.*),
                else => false,
            },
            .array => |arr| switch (b) {
                .array => |barr| arr.len == barr.len and self.typeEquals(arr.elem.*, barr.elem.*),
                else => false,
            },
            .slice => |s| switch (b) {
                .slice => |bs| self.typeEquals(s.elem.*, bs.elem.*),
                else => false,
            },
            else => std.meta.eql(a, b),
        };
    }

    fn emitIndent(self: *Codegen) CodegenError!void {
        for (0..self.indent_level) |_| {
            try self.emit("    ");
        }
    }

    // ── Output helpers ──────────────────────────────────────────

    fn emit(self: *Codegen, s: []const u8) CodegenError!void {
        self.output.appendSlice(self.allocator, s) catch return CodegenError.OutOfMemory;
    }

    fn emitTo(self: *Codegen, out: *std.ArrayList(u8), s: []const u8) CodegenError!void {
        out.appendSlice(self.allocator, s) catch return CodegenError.OutOfMemory;
    }

    fn emitArrayDimsTo(self: *Codegen, out: *std.ArrayList(u8), t: ast.Type) CodegenError!void {
        switch (t) {
            .array => |arr| {
                try self.emitTo(out, "[");
                var buf: [32]u8 = undefined;
                const len_str = std.fmt.bufPrint(&buf, "{d}", .{arr.len}) catch return CodegenError.OutOfMemory;
                try self.emitTo(out, len_str);
                try self.emitTo(out, "]");
                try self.emitArrayDimsTo(out, arr.elem.*);
            },
            else => {},
        }
    }
};
