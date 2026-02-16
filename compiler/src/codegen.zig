/// C code generator for 1im.
/// Walks the AST and emits C source code that can be compiled with any C compiler.
const std = @import("std");
const ast = @import("ast.zig");

pub const CodegenError = error{
    UnsupportedNode,
    UnknownVariable,
    OutOfMemory,
};

/// Tracks inferred types for variables during codegen.
const ValueType = enum {
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    boolean,
    string,
    unknown,

    pub fn fromAstType(t: ast.Type) ValueType {
        return switch (t) {
            .i8 => .i8,
            .i16 => .i16,
            .i32 => .i32,
            .i64 => .i64,
            .u8 => .u8,
            .u16 => .u16,
            .u32 => .u32,
            .u64 => .u64,
            .f32 => .f32,
            .f64 => .f64,
            .bool => .boolean,
            .str => .string,
            .void => .unknown,
        };
    }
};

pub const Codegen = struct {
    output: std.ArrayList(u8),
    var_types: std.StringHashMap(ValueType),
    indent_level: usize,
    in_function: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Codegen {
        return .{
            .output = .empty,
            .var_types = std.StringHashMap(ValueType).init(allocator),
            .indent_level = 1,
            .in_function = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Codegen) void {
        self.output.deinit(self.allocator);
        self.var_types.deinit();
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
        try self.emit("\n");

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

    fn emitStmt(self: *Codegen, node: ast.Node) CodegenError!void {
        switch (node) {
            .set_assign => |sa| try self.emitSetAssign(sa),
            .typed_assign => |ta| try self.emitTypedAssign(ta),
            .function_def => |fd| try self.emitFunctionDef(fd),
            .return_stmt => |rs| try self.emitReturn(rs),
            .if_stmt => |is| try self.emitIf(is),
            .while_loop => |wl| try self.emitWhile(wl),
            .for_loop => |fl| try self.emitFor(fl),
            .break_stmt => try self.emitBreak(),
            .continue_stmt => try self.emitContinue(),
            .try_catch => |tc| try self.emitTryCatch(tc),
            .expr_stmt => |es| try self.emitExprStmt(es),
            else => return CodegenError.UnsupportedNode,
        }
    }

    fn emitSetAssign(self: *Codegen, sa: ast.SetAssign) CodegenError!void {
        const val_type = self.inferType(sa.value.*);

        // Check if variable already declared
        const already_declared = self.var_types.contains(sa.name);

        if (!already_declared) {
            // Record variable type
            self.var_types.put(sa.name, val_type) catch return CodegenError.OutOfMemory;

            // Emit C declaration
            try self.emitIndent();
            try self.emit(self.valueToCType(val_type));
            try self.emit(" ");
            try self.emit(sa.name);
            try self.emit(" = ");
            try self.emitExpr(sa.value.*);
            try self.emit(";\n");
        } else {
            // Emit assignment (variable already declared)
            try self.emitIndent();
            try self.emit(sa.name);
            try self.emit(" = ");
            try self.emitExpr(sa.value.*);
            try self.emit(";\n");
        }
    }

    fn emitTypedAssign(self: *Codegen, ta: ast.TypedAssign) CodegenError!void {
        const val_type = ValueType.fromAstType(ta.type_info);

        // Check if variable already declared
        const already_declared = self.var_types.contains(ta.name);

        if (!already_declared) {
            // Record variable type
            self.var_types.put(ta.name, val_type) catch return CodegenError.OutOfMemory;

            // Emit C declaration with explicit type
            try self.emitIndent();
            try self.emit(ta.type_info.toCString());
            try self.emit(" ");
            try self.emit(ta.name);
            try self.emit(" = ");
            try self.emitExpr(ta.value.*);
            try self.emit(";\n");
        } else {
            // Emit assignment (variable already declared)
            try self.emitIndent();
            try self.emit(ta.name);
            try self.emit(" = ");
            try self.emitExpr(ta.value.*);
            try self.emit(";\n");
        }
    }

    fn emitFunctionDecl(self: *Codegen, fd: ast.FunctionDef) CodegenError!void {
        // Forward declaration
        if (fd.return_type) |ret| {
            try self.emit(ret.toCString());
        } else {
            try self.emit("void");
        }
        try self.emit(" ");
        try self.emit(fd.name);
        try self.emit("(");

        for (fd.params, 0..) |param, i| {
            if (i > 0) try self.emit(", ");
            try self.emit(param.type_info.toCString());
            try self.emit(" ");
            try self.emit(param.name);
        }

        try self.emit(");\n");
    }

    fn emitFunctionDef(self: *Codegen, fd: ast.FunctionDef) CodegenError!void {
        // Record parameter types
        for (fd.params) |param| {
            const ptype = ValueType.fromAstType(param.type_info);
            self.var_types.put(param.name, ptype) catch return CodegenError.OutOfMemory;
        }

        // Function signature
        if (fd.return_type) |ret| {
            try self.emit(ret.toCString());
        } else {
            try self.emit("void");
        }
        try self.emit(" ");
        try self.emit(fd.name);
        try self.emit("(");

        for (fd.params, 0..) |param, i| {
            if (i > 0) try self.emit(", ");
            try self.emit(param.type_info.toCString());
            try self.emit(" ");
            try self.emit(param.name);
        }

        try self.emit(") {\n");

        const old_in_function = self.in_function;
        self.in_function = true;
        self.indent_level += 1;

        // Emit body
        for (fd.body) |stmt| {
            try self.emitStmt(stmt);
        }

        self.indent_level -= 1;
        self.in_function = old_in_function;
        try self.emit("}\n\n");
    }

    fn emitReturn(self: *Codegen, rs: ast.ReturnStmt) CodegenError!void {
        try self.emitIndent();
        try self.emit("return");
        if (rs.value) |val| {
            try self.emit(" ");
            try self.emitExpr(val.*);
        }
        try self.emit(";\n");
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
        // For now, emit comment - proper for loop requires range support
        try self.emitIndent();
        try self.emit("// For loop not fully implemented\n");
        try self.emitIndent();
        try self.emit("// loop for ");
        try self.emit(fl.variable);
        try self.emit(" in ...\n");
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
        // Simplified - not real error unions yet
        try self.emitIndent();
        try self.emit("// try/catch not fully implemented\n");
        try self.emitIndent();
        try self.emit("{");
        try self.emitExpr(tc.try_expr.*);
        try self.emit("}\n");
    }

    fn emitExprStmt(self: *Codegen, es: ast.ExprStmt) CodegenError!void {
        switch (es.expr.*) {
            .call => |c| try self.emitCall(c),
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
            .boolean => {
                try self.emit("printf(\"%s\\n\", ");
                try self.emitExpr(arg);
                try self.emit(" ? \"true\" : \"false\");\n");
            },
            .string => {
                try self.emit("printf(\"%s\\n\", ");
                try self.emitExpr(arg);
                try self.emit(");\n");
            },
            .unknown => {
                // Default: try as integer
                try self.emit("printf(\"%\" PRId64 \"\\n\", (int64_t)");
                try self.emitExpr(arg);
                try self.emit(");\n");
            },
        }
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
                try self.emit(c.callee);
                try self.emit("(");
                for (c.args, 0..) |arg, i| {
                    if (i > 0) try self.emit(", ");
                    try self.emitExpr(arg);
                }
                try self.emit(")");
            },
            else => return CodegenError.UnsupportedNode,
        }
    }

    // ── Type inference (minimal) ────────────────────────────────

    fn inferType(self: *const Codegen, node: ast.Node) ValueType {
        return switch (node) {
            .int_literal => .i64, // default to i64
            .float_literal => .f64, // default to f64
            .string_literal => .string,
            .bool_literal => .boolean,
            .null_literal => .unknown,
            .variable => |v| self.var_types.get(v.name) orelse .unknown,
            .binary_op => |bin| {
                const lt = self.inferType(bin.left.*);
                const rt = self.inferType(bin.right.*);
                // If either is float, result is float
                if (self.isFloatType(lt) or self.isFloatType(rt)) {
                    if (self.isFloatType(lt)) return lt;
                    return rt;
                }
                // If either is 64-bit, result is 64-bit
                if (lt == .i64 or rt == .i64) return .i64;
                if (lt == .u64 or rt == .u64) return .u64;
                return lt;
            },
            .unary_op => |un| self.inferType(un.operand.*),
            .call => .unknown,
            else => .unknown,
        };
    }

    fn isFloatType(self: *const Codegen, t: ValueType) bool {
        _ = self;
        return t == .f32 or t == .f64;
    }

    fn valueToCType(self: *const Codegen, t: ValueType) []const u8 {
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
            .boolean => "bool",
            .string => "const char*",
            .unknown => "int64_t", // default fallback
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
};
