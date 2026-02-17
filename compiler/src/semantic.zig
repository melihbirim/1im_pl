const std = @import("std");
const ast = @import("ast.zig");

pub const SemanticError = error{
    Failure,
};

const SemType = union(enum) {
    known: ast.Type,
    null,
    int_lit,
    float_lit,
};

const FunctionSig = struct {
    params: []const ast.Param,
    return_type: ?ast.Type,
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    scopes: std.ArrayList(std.StringHashMap(ast.Type)),
    functions: std.StringHashMap(FunctionSig),
    inferred_returns: std.StringHashMap(ast.Type),
    return_stack: std.ArrayList(?ast.Type),
    last_error: []const u8,
    in_function: bool,
    loop_depth: usize,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .scopes = .empty,
            .functions = std.StringHashMap(FunctionSig).init(allocator),
            .inferred_returns = std.StringHashMap(ast.Type).init(allocator),
            .return_stack = .empty,
            .last_error = "",
            .in_function = false,
            .loop_depth = 0,
        };
    }

    pub fn deinit(self: *Analyzer) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit(self.allocator);
        self.functions.deinit();
        self.inferred_returns.deinit();
        self.return_stack.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn analyze(self: *Analyzer, program: ast.Node) SemanticError!void {
        const prog = switch (program) {
            .program => |p| p,
            else => return self.fail("semantic error: expected program root"),
        };

        try self.pushScope();
        defer self.popScope();

        // Collect function signatures.
        for (prog.stmts) |stmt| {
            if (stmt == .function_def) {
                if (self.functions.contains(stmt.function_def.name)) {
                    return self.fail("semantic error: duplicate function name");
                }
                self.functions.put(stmt.function_def.name, .{
                    .params = stmt.function_def.params,
                    .return_type = stmt.function_def.return_type,
                }) catch return self.fail("semantic error: out of memory");
            }
        }

        try self.inferMissingFunctionReturns(prog);

        for (prog.stmts) |stmt| {
            try self.checkStmt(stmt);
        }
    }

    fn checkStmt(self: *Analyzer, node: ast.Node) SemanticError!void {
        switch (node) {
            .set_assign => |sa| try self.checkSetAssign(sa),
            .typed_assign => |ta| try self.checkTypedAssign(ta),
            .index_assign => |ia| try self.checkIndexAssign(ia),
            .function_def => |fd| try self.checkFunctionDef(fd),
            .return_stmt => |rs| try self.checkReturn(rs),
            .if_stmt => |is| try self.checkIf(is),
            .while_loop => |wl| try self.checkWhile(wl),
            .for_loop => |fl| try self.checkFor(fl),
            .parallel_block => |pb| try self.checkParallelBlock(pb),
            .break_stmt => try self.checkBreak(),
            .continue_stmt => try self.checkContinue(),
            .try_catch => |tc| try self.checkTryCatch(tc),
            .expr_stmt => |es| {
                if (self.containsTryExpr(es.expr.*) and es.expr.* != .try_expr) {
                    return self.fail("semantic error: try expression must be used directly in assignment or return");
                }
                _ = try self.inferExprType(es.expr.*);
            },
            else => return self.fail("semantic error: unsupported statement"),
        }
    }

    fn checkSetAssign(self: *Analyzer, sa: ast.SetAssign) SemanticError!void {
        if (self.containsTryExpr(sa.value.*) and sa.value.* != .try_expr) {
            return self.fail("semantic error: try expression must be used directly in assignment or return");
        }
        const value_type = try self.inferExprType(sa.value.*);

        if (self.lookupVar(sa.name)) |existing| {
            if (existing == .array and sa.value.* == .array_literal) {
                return self.fail("semantic error: array reassignment not supported");
            }
            try self.ensureAssignable(existing, value_type);
            return;
        }

        const inferred = switch (value_type) {
            .known => |kt| kt,
            .int_lit => .i32,
            .float_lit => .f64,
            .null => return self.fail("semantic error: cannot infer type from null"),
        };
        if (self.typeEquals(inferred, .void)) return self.fail("semantic error: cannot assign void value");
        try self.declareVar(sa.name, inferred, false);
    }

    fn checkTypedAssign(self: *Analyzer, ta: ast.TypedAssign) SemanticError!void {
        if (self.lookupVarAnyScope(ta.name)) {
            return self.fail("semantic error: typed declaration shadows an existing name");
        }

        try self.validateType(ta.type_info);

        if (self.containsTryExpr(ta.value.*) and ta.value.* != .try_expr) {
            return self.fail("semantic error: try expression must be used directly in assignment or return");
        }
        const value_type = try self.inferExprType(ta.value.*);
        if (ta.type_info == .slice) {
            if (ta.type_info.slice.elem.* == .array) {
                return self.fail("semantic error: slice of arrays not supported");
            }
            switch (value_type) {
                .known => |kt| switch (kt) {
                    .array => |arr| {
                        if (!self.typeEquals(arr.elem.*, ta.type_info.slice.elem.*)) {
                            return self.fail("semantic error: slice element type mismatch");
                        }
                    },
                    .slice => |s| {
                        if (!self.typeEquals(s.elem.*, ta.type_info.slice.elem.*)) {
                            return self.fail("semantic error: slice element type mismatch");
                        }
                    },
                    else => return self.fail("semantic error: slice assignment requires array or slice"),
                },
                else => return self.fail("semantic error: slice assignment requires array or slice"),
            }
        } else {
            try self.ensureAssignable(ta.type_info, value_type);
        }
        try self.declareVar(ta.name, ta.type_info, true);
    }

    fn checkFunctionDef(self: *Analyzer, fd: ast.FunctionDef) SemanticError!void {
        const prev_in_function = self.in_function;
        self.in_function = true;

        const inferred = self.inferred_returns.get(fd.name);
        const return_type = fd.return_type orelse inferred;
        self.return_stack.append(self.allocator, return_type) catch return self.fail("semantic error: out of memory");
        defer _ = self.return_stack.pop();

        try self.pushScope();
        defer self.popScope();

        for (fd.params) |param| {
            try self.validateType(param.type_info);
            if (self.lookupVarAnyScope(param.name)) {
                return self.fail("semantic error: parameter shadows an existing name");
            }
            try self.declareVar(param.name, param.type_info, true);
        }

        for (fd.body) |stmt| {
            try self.checkStmt(stmt);
        }

        if (return_type) |ret_type| {
            try self.validateType(ret_type);
            if (!self.blockReturns(fd.body)) {
                return self.fail("semantic error: non-void function must return on all paths");
            }
        }

        self.in_function = prev_in_function;
    }

    fn checkReturn(self: *Analyzer, rs: ast.ReturnStmt) SemanticError!void {
        if (!self.in_function) {
            return self.fail("semantic error: return outside of function");
        }

        const ret_type = self.currentFunctionReturnType() orelse return self.fail("semantic error: return not allowed here");

        if (ret_type == null) {
            if (rs.value != null) return self.fail("semantic error: return value in void function");
            return;
        }

        if (rs.value == null) return self.fail("semantic error: missing return value");
        if (self.containsTryExpr(rs.value.?.*) and rs.value.?.* != .try_expr) {
            return self.fail("semantic error: try expression must be used directly in assignment or return");
        }
        const value_type = try self.inferExprType(rs.value.?.*);
        try self.ensureAssignable(ret_type.?, value_type);
    }

    fn checkIf(self: *Analyzer, is: ast.IfStmt) SemanticError!void {
        const cond_type = try self.inferExprType(is.condition.*);
        try self.ensureBool(cond_type);

        try self.pushScope();
        defer self.popScope();
        for (is.then_body) |stmt| {
            try self.checkStmt(stmt);
        }

        for (is.else_ifs) |elif| {
            const elif_type = try self.inferExprType(elif.condition.*);
            try self.ensureBool(elif_type);

            try self.pushScope();
            defer self.popScope();
            for (elif.body) |stmt| {
                try self.checkStmt(stmt);
            }
        }

        if (is.else_body) |else_body| {
            try self.pushScope();
            defer self.popScope();
            for (else_body) |stmt| {
                try self.checkStmt(stmt);
            }
        }
    }

    fn checkWhile(self: *Analyzer, wl: ast.WhileLoop) SemanticError!void {
        if (wl.parallel) {
            return self.fail("semantic error: parallel while not supported");
        }
        const cond_type = try self.inferExprType(wl.condition.*);
        try self.ensureBool(cond_type);

        self.loop_depth += 1;
        defer self.loop_depth -= 1;

        try self.pushScope();
        defer self.popScope();

        for (wl.body) |stmt| {
            try self.checkStmt(stmt);
        }
    }

    fn checkFor(self: *Analyzer, fl: ast.ForLoop) SemanticError!void {
        var loop_var_type: ast.Type = undefined;

        switch (fl.iterable.*) {
            .range => |range| {
                const start_t = try self.inferExprType(range.start.*);
                const end_t = try self.inferExprType(range.end.*);
                const start_type = try self.rangeEndpointType(start_t);
                const end_type = try self.rangeEndpointType(end_t);
                if (!self.typeEquals(start_type, end_type)) {
                    return self.fail("semantic error: for range endpoints must match types");
                }
                loop_var_type = start_type;
            },
            else => {
                const iter_type = try self.inferExprType(fl.iterable.*);
                const kt = try self.requireKnownType(iter_type, "semantic error: for loop requires array or slice");
                switch (kt) {
                    .array => |arr| {
                        if (fl.iterable.* != .variable) {
                            return self.fail("semantic error: for array requires variable iterable");
                        }
                        if (arr.elem.* == .array) {
                            return self.fail("semantic error: for array of arrays not supported");
                        }
                        loop_var_type = arr.elem.*;
                    },
                    .slice => |s| {
                        if (s.elem.* == .array) {
                            return self.fail("semantic error: for slice of arrays not supported");
                        }
                        loop_var_type = s.elem.*;
                    },
                    else => return self.fail("semantic error: for loop requires array or slice"),
                }
            },
        }

        if (self.lookupVarAnyScope(fl.variable)) {
            return self.fail("semantic error: loop variable shadows an existing name");
        }

        self.loop_depth += 1;
        defer self.loop_depth -= 1;

        try self.pushScope();
        defer self.popScope();

        try self.declareVar(fl.variable, loop_var_type, true);
        for (fl.body) |stmt| {
            try self.checkStmt(stmt);
        }
    }

    fn checkParallelBlock(self: *Analyzer, pb: ast.ParallelBlock) SemanticError!void {
        for (pb.body) |stmt| {
            switch (stmt) {
                .expr_stmt => |es| switch (es.expr.*) {
                    .call => |c| {
                        if (c.args.len != 0) {
                            return self.fail("semantic error: parallel block calls cannot take arguments");
                        }
                        _ = try self.checkCall(c);
                    },
                    else => return self.fail("semantic error: parallel block only supports function calls"),
                },
                else => return self.fail("semantic error: parallel block only supports function calls"),
            }
        }
    }

    fn checkTryCatch(self: *Analyzer, tc: ast.TryCatch) SemanticError!void {
        const try_type = try self.inferExprType(tc.try_expr.*);
        const eu = try self.requireErrorUnion(try_type, "semantic error: try requires error union");

        try self.pushScope();
        defer self.popScope();

        if (tc.catch_var) |name| {
            if (self.lookupVarAnyScope(name)) {
                return self.fail("semantic error: catch variable shadows an existing name");
            }
            try self.declareVar(name, eu.err.*, true);
        }

        for (tc.catch_body) |stmt| {
            try self.checkStmt(stmt);
        }
    }

    fn checkBreak(self: *Analyzer) SemanticError!void {
        if (self.loop_depth == 0) {
            return self.fail("semantic error: break outside of loop");
        }
    }

    fn checkContinue(self: *Analyzer) SemanticError!void {
        if (self.loop_depth == 0) {
            return self.fail("semantic error: continue outside of loop");
        }
    }

    fn inferExprType(self: *Analyzer, node: ast.Node) SemanticError!SemType {
        return switch (node) {
            .int_literal => .int_lit,
            .float_literal => .float_lit,
            .string_literal => .{ .known = .str },
            .bool_literal => .{ .known = .bool },
            .null_literal => .null,
            .variable => |v| blk: {
                if (self.lookupVar(v.name)) |t| break :blk .{ .known = t };
                return self.fail("semantic error: undefined variable");
            },
            .binary_op => |bin| try self.checkBinary(bin),
            .unary_op => |un| try self.checkUnary(un),
            .call => |c| try self.checkCall(c),
            .array_literal => |arr| try self.checkArrayLiteral(arr),
            .index_expr => |ix| try self.checkIndex(ix),
            .try_expr => |te| {
                const inner = try self.inferExprType(te.expr.*);
                const eu = try self.requireErrorUnion(inner, "semantic error: try requires error union");

                const ret_type = self.currentFunctionReturnType() orelse return self.fail("semantic error: try outside of function");
                if (ret_type == null) return self.fail("semantic error: try requires error-union function return");
                if (ret_type.? != .error_union) return self.fail("semantic error: try requires error-union function return");
                if (!self.typeEquals(ret_type.?.error_union.err.*, eu.err.*)) {
                    return self.fail("semantic error: try error type must match function error type");
                }

                return .{ .known = eu.ok.* };
            },
            .range => return self.fail("semantic error: range is only valid in for loop"),
            else => return self.fail("semantic error: unsupported expression"),
        };
    }

    fn checkBinary(self: *Analyzer, bin: ast.BinaryOp) SemanticError!SemType {
        const lt = try self.inferExprType(bin.left.*);
        const rt = try self.inferExprType(bin.right.*);

        switch (bin.op) {
            .add, .sub, .mul, .div, .mod => {
                return try self.inferNumericBinary(lt, rt);
            },
            .eq, .neq => {
                try self.ensureComparable(lt, rt);
                return .{ .known = .bool };
            },
            .lt, .lte, .gt, .gte => {
                try self.ensureComparable(lt, rt);
                return .{ .known = .bool };
            },
            .bool_and, .bool_or => {
                try self.ensureBool(lt);
                try self.ensureBool(rt);
                return .{ .known = .bool };
            },
        }
    }

    fn checkUnary(self: *Analyzer, un: ast.UnaryOp) SemanticError!SemType {
        const ot = try self.inferExprType(un.operand.*);
        switch (un.op) {
            .negate => {
                const t = try self.resolveLiteralType(ot, "unary - requires numeric type");
                if (!self.isNumeric(t)) return self.fail("semantic error: unary - requires numeric type");
                return .{ .known = t };
            },
            .bool_not => {
                try self.ensureBool(ot);
                return .{ .known = .bool };
            },
        }
    }

    fn checkArrayLiteral(self: *Analyzer, arr: ast.ArrayLiteral) SemanticError!SemType {
        if (arr.elements.len == 0) {
            return self.fail("semantic error: empty array literal requires type annotation");
        }

        const first_type = try self.inferExprType(arr.elements[0]);
        const elem_type = try self.resolveLiteralType(first_type, "semantic error: cannot infer array element type");

        for (arr.elements) |elem| {
            const t = try self.inferExprType(elem);
            try self.ensureAssignable(elem_type, t);
        }

        const elem_ptr = try self.allocType(elem_type);
        return .{ .known = .{ .array = .{ .len = arr.elements.len, .elem = elem_ptr } } };
    }

    fn checkIndex(self: *Analyzer, ix: ast.IndexExpr) SemanticError!SemType {
        const target_type = try self.inferExprType(ix.target.*);
        const index_type = try self.inferExprType(ix.index.*);
        const index_resolved = try self.resolveLiteralType(index_type, "semantic error: index must be integer");
        if (!self.isInteger(index_resolved)) return self.fail("semantic error: index must be integer");

        switch (target_type) {
            .known => |kt| switch (kt) {
                .array => |arr| return .{ .known = arr.elem.* },
                .slice => |s| return .{ .known = s.elem.* },
                else => return self.fail("semantic error: cannot index non-array"),
            },
            else => return self.fail("semantic error: cannot index non-array"),
        }
    }

    fn checkIndexAssign(self: *Analyzer, ia: ast.IndexAssign) SemanticError!void {
        const value_type = try self.inferExprType(ia.value.*);
        switch (ia.target.*) {
            .index_expr => |ix| {
                const elem_type = try self.checkIndex(ix);
                try self.ensureAssignable(elem_type.known, value_type);
            },
            else => return self.fail("semantic error: cannot assign to non-array"),
        }
    }

    fn checkCall(self: *Analyzer, call: ast.Call) SemanticError!SemType {
        if (std.mem.eql(u8, call.callee, "print")) {
            if (call.args.len > 1) {
                return self.fail("semantic error: print accepts at most one argument");
            }
            if (call.args.len == 1) {
                _ = try self.inferExprType(call.args[0]);
            }
            return .{ .known = .void };
        }
        if (std.mem.eql(u8, call.callee, "len")) {
            if (call.args.len != 1) {
                return self.fail("semantic error: len expects exactly one argument");
            }
            const arg_type = try self.inferExprType(call.args[0]);
            switch (arg_type) {
                .known => |kt| switch (kt) {
                    .array, .slice => return .{ .known = .i32 },
                    else => return self.fail("semantic error: len expects array or slice"),
                },
                else => return self.fail("semantic error: len expects array or slice"),
            }
        }

        const sig = self.functions.get(call.callee) orelse return self.fail("semantic error: unknown function");
        if (call.args.len != sig.params.len) {
            return self.fail("semantic error: incorrect argument count");
        }

        for (call.args, 0..) |arg, i| {
            const arg_type = try self.inferExprType(arg);
            const expected = sig.params[i].type_info;
            try self.ensureAssignable(expected, arg_type);
        }

        if (sig.return_type) |ret| {
            return .{ .known = ret };
        }
        if (self.inferred_returns.get(call.callee)) |ret| {
            return .{ .known = ret };
        }
        return .{ .known = .void };
    }

    fn ensureBool(self: *Analyzer, t: SemType) SemanticError!void {
        const kt = try self.requireKnownType(t, "expected bool");
        if (!self.typeEquals(kt, .bool)) return self.fail("semantic error: expected bool");
    }

    fn ensureAssignable(self: *Analyzer, expected: ast.Type, actual: SemType) SemanticError!void {
        if (expected == .error_union) {
            const eu = expected.error_union;
            switch (actual) {
                .null => {
                    if (self.typeEquals(eu.ok.*, .str)) return;
                    if (self.typeEquals(eu.err.*, .str)) return;
                    return self.fail("semantic error: null only assignable to str (for now)");
                },
                .int_lit => {
                    if (self.isInteger(eu.ok.*)) return;
                    return self.fail("semantic error: expected integer type");
                },
                .float_lit => {
                    if (self.isFloat(eu.ok.*)) return;
                    return self.fail("semantic error: expected float type");
                },
                .known => |kt| {
                    if (self.typeEquals(kt, expected)) return;
                    if (self.typeEquals(kt, eu.ok.*)) return;
                    if (self.typeEquals(kt, eu.err.*)) return;
                    return self.fail("semantic error: type mismatch");
                },
            }
        }

        switch (actual) {
            .null => {
                if (!self.typeEquals(expected, .str)) {
                    return self.fail("semantic error: null only assignable to str (for now)");
                }
            },
            .int_lit => {
                if (!self.isInteger(expected)) return self.fail("semantic error: expected integer type");
            },
            .float_lit => {
                if (!self.isFloat(expected)) return self.fail("semantic error: expected float type");
            },
            .known => |kt| {
                if (!self.typeEquals(kt, expected)) return self.fail("semantic error: type mismatch");
            },
        }
    }

    fn requireKnownType(self: *Analyzer, t: SemType, msg: []const u8) SemanticError!ast.Type {
        switch (t) {
            .known => |kt| return kt,
            .null => return self.fail(msg),
            .int_lit => return self.fail(msg),
            .float_lit => return self.fail(msg),
        }
    }

    fn resolveLiteralType(self: *Analyzer, t: SemType, msg: []const u8) SemanticError!ast.Type {
        switch (t) {
            .known => |kt| return kt,
            .int_lit => return .i32,
            .float_lit => return .f64,
            .null => return self.fail(msg),
        }
    }

    fn isNumeric(self: *Analyzer, t: ast.Type) bool {
        _ = self;
        return switch (t) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .f32, .f64 => true,
            else => false,
        };
    }

    fn isInteger(self: *Analyzer, t: ast.Type) bool {
        _ = self;
        return switch (t) {
            .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64 => true,
            else => false,
        };
    }

    fn isFloat(self: *Analyzer, t: ast.Type) bool {
        _ = self;
        return t == .f32 or t == .f64;
    }

    fn inferNumericBinary(self: *Analyzer, lt: SemType, rt: SemType) SemanticError!SemType {
        switch (lt) {
            .int_lit => switch (rt) {
                .int_lit => return .int_lit,
                .known => |rk| {
                    if (!self.isInteger(rk)) return self.fail("semantic error: numeric types must match");
                    return .{ .known = rk };
                },
                .float_lit => return self.fail("semantic error: numeric types must match"),
                else => return self.fail("semantic error: binary op requires numeric types"),
            },
            .float_lit => switch (rt) {
                .float_lit => return .float_lit,
                .known => |rk| {
                    if (!self.isFloat(rk)) return self.fail("semantic error: numeric types must match");
                    return .{ .known = rk };
                },
                .int_lit => return self.fail("semantic error: numeric types must match"),
                else => return self.fail("semantic error: binary op requires numeric types"),
            },
            .known => |lk| switch (rt) {
                .int_lit => {
                    if (!self.isInteger(lk)) return self.fail("semantic error: numeric types must match");
                    return .{ .known = lk };
                },
                .float_lit => {
                    if (!self.isFloat(lk)) return self.fail("semantic error: numeric types must match");
                    return .{ .known = lk };
                },
                .known => |rk| {
                    if (!self.isNumeric(lk) or !self.isNumeric(rk)) {
                        return self.fail("semantic error: binary op requires numeric types");
                    }
                    if (!self.typeEquals(lk, rk)) return self.fail("semantic error: numeric types must match");
                    return .{ .known = lk };
                },
                else => return self.fail("semantic error: binary op requires numeric types"),
            },
            else => return self.fail("semantic error: binary op requires numeric types"),
        }
    }

    fn ensureComparable(self: *Analyzer, lt: SemType, rt: SemType) SemanticError!void {
        switch (lt) {
            .int_lit => switch (rt) {
                .int_lit => return,
                .known => |rk| if (!self.isInteger(rk)) return self.fail("semantic error: comparison types must match"),
                .float_lit => return self.fail("semantic error: comparison types must match"),
                else => return self.fail("semantic error: comparison types must match"),
            },
            .float_lit => switch (rt) {
                .float_lit => return,
                .known => |rk| if (!self.isFloat(rk)) return self.fail("semantic error: comparison types must match"),
                .int_lit => return self.fail("semantic error: comparison types must match"),
                else => return self.fail("semantic error: comparison types must match"),
            },
            .known => |lk| switch (rt) {
                .int_lit => if (!self.isInteger(lk)) return self.fail("semantic error: comparison types must match"),
                .float_lit => if (!self.isFloat(lk)) return self.fail("semantic error: comparison types must match"),
                .known => |rk| {
                    if (!self.typeEquals(lk, rk)) return self.fail("semantic error: comparison types must match");
                },
                else => return self.fail("semantic error: comparison types must match"),
            },
            else => return self.fail("semantic error: comparison types must match"),
        }
    }

    fn allocType(self: *Analyzer, t: ast.Type) SemanticError!*ast.Type {
        const t_ptr = self.arena.allocator().create(ast.Type) catch return self.fail("semantic error: out of memory");
        t_ptr.* = t;
        return t_ptr;
    }

    fn rangeEndpointType(self: *Analyzer, t: SemType) SemanticError!ast.Type {
        switch (t) {
            .known => |kt| {
                if (kt == .error_union) return self.fail("semantic error: for range requires integer type");
                if (!self.isInteger(kt)) return self.fail("semantic error: for range requires integer type");
                return kt;
            },
            .int_lit => return .i32,
            .float_lit => return self.fail("semantic error: for range requires integer type"),
            .null => return self.fail("semantic error: for range requires integer type"),
        }
    }

    fn declareVar(self: *Analyzer, name: []const u8, t: ast.Type, typed: bool) SemanticError!void {
        _ = typed;
        var scope = &self.scopes.items[self.scopes.items.len - 1];
        if (scope.contains(name)) {
            return self.fail("semantic error: duplicate declaration in same scope");
        }
        scope.put(name, t) catch return self.fail("semantic error: out of memory");
    }

    fn lookupVar(self: *Analyzer, name: []const u8) ?ast.Type {
        var i: usize = self.scopes.items.len;
        while (i > 0) : (i -= 1) {
            if (self.scopes.items[i - 1].get(name)) |t| return t;
        }
        return null;
    }

    fn lookupVarAnyScope(self: *Analyzer, name: []const u8) bool {
        return self.lookupVar(name) != null;
    }

    fn pushScope(self: *Analyzer) SemanticError!void {
        const map = std.StringHashMap(ast.Type).init(self.allocator);
        self.scopes.append(self.allocator, map) catch return self.fail("semantic error: out of memory");
    }

    fn popScope(self: *Analyzer) void {
        if (self.scopes.pop()) |scope| {
            var mutable_scope = scope;
            mutable_scope.deinit();
        }
    }

    fn blockReturns(self: *Analyzer, stmts: []const ast.Node) bool {
        if (stmts.len == 0) return false;
        return self.stmtReturns(stmts[stmts.len - 1]);
    }

    fn stmtReturns(self: *Analyzer, stmt: ast.Node) bool {
        return switch (stmt) {
            .return_stmt => true,
            .if_stmt => |is| blk: {
                if (is.else_body == null) break :blk false;
                for (is.else_ifs) |elif| {
                    if (!self.blockReturns(elif.body)) break :blk false;
                }
                if (!self.blockReturns(is.then_body)) break :blk false;
                if (!self.blockReturns(is.else_body.?)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    fn typeEquals(self: *Analyzer, a: ast.Type, b: ast.Type) bool {
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

    fn validateType(self: *Analyzer, t: ast.Type) SemanticError!void {
        switch (t) {
            .error_union => |eu| {
                if (self.typeEquals(eu.ok.*, eu.err.*)) {
                    return self.fail("semantic error: error union ok and err types must differ");
                }
                if (eu.ok.* == .array or eu.err.* == .array) {
                    return self.fail("semantic error: error unions cannot contain array types");
                }
                if (eu.ok.* == .error_union or eu.err.* == .error_union) {
                    return self.fail("semantic error: nested error unions not supported");
                }
                try self.validateType(eu.ok.*);
                try self.validateType(eu.err.*);
            },
            .array => |arr| try self.validateType(arr.elem.*),
            .slice => |s| {
                if (s.elem.* == .array) {
                    return self.fail("semantic error: slice of arrays not supported");
                }
                try self.validateType(s.elem.*);
            },
            else => {},
        }
    }

    fn requireErrorUnion(self: *Analyzer, t: SemType, msg: []const u8) SemanticError!ast.ErrorUnionType {
        const kt = try self.requireKnownType(t, msg);
        return switch (kt) {
            .error_union => |eu| eu,
            else => return self.fail(msg),
        };
    }

    fn currentFunctionReturnType(self: *Analyzer) ??ast.Type {
        if (self.return_stack.items.len == 0) return null;
        return self.return_stack.items[self.return_stack.items.len - 1];
    }

    fn fail(self: *Analyzer, msg: []const u8) SemanticError {
        self.last_error = msg;
        return SemanticError.Failure;
    }

    fn inferMissingFunctionReturns(self: *Analyzer, prog: ast.Program) SemanticError!void {
        for (prog.stmts) |stmt| {
            if (stmt != .function_def) continue;
            const fd = stmt.function_def;
            if (fd.return_type != null) continue;

            const inferred = try self.inferFunctionReturnType(fd);
            if (inferred) |ret| {
                try self.validateType(ret);
                self.inferred_returns.put(fd.name, ret) catch return self.fail("semantic error: out of memory");
            }
        }
    }

    fn inferFunctionReturnType(self: *Analyzer, fd: ast.FunctionDef) SemanticError!?ast.Type {
        var has_value = false;
        var has_void = false;
        var inferred: ast.Type = undefined;

        try self.pushScope();
        defer self.popScope();

        for (fd.params) |param| {
            try self.declareVar(param.name, param.type_info, true);
        }

        try self.inferReturnTypesInBlock(fd.body, &has_value, &has_void, &inferred);

        if (has_void and has_value) {
            return self.fail("semantic error: mixed return values and bare return");
        }
        if (has_value) return inferred;
        return null;
    }

    fn inferReturnTypesInBlock(
        self: *Analyzer,
        stmts: []const ast.Node,
        has_value: *bool,
        has_void: *bool,
        inferred: *ast.Type,
    ) SemanticError!void {
        for (stmts) |stmt| {
            try self.collectReturnType(stmt, has_value, has_void, inferred);
        }
    }

    fn collectReturnType(
        self: *Analyzer,
        stmt: ast.Node,
        has_value: *bool,
        has_void: *bool,
        inferred: *ast.Type,
    ) SemanticError!void {
        switch (stmt) {
            .set_assign => |sa| try self.checkSetAssign(sa),
            .typed_assign => |ta| try self.checkTypedAssign(ta),
            .index_assign => |ia| try self.checkIndexAssign(ia),
            .return_stmt => |rs| {
                if (rs.value == null) {
                    has_void.* = true;
                    return;
                }

                var ret_type: ast.Type = undefined;
                if (rs.value.?.* == .try_expr) {
                    const inner = try self.inferExprType(rs.value.?.*.try_expr.expr.*);
                    const eu = try self.requireErrorUnion(inner, "semantic error: try requires error union");
                    ret_type = .{ .error_union = eu };
                } else {
                    const value_type = try self.inferExprType(rs.value.?.*);
                    ret_type = try self.resolveLiteralType(value_type, "semantic error: cannot infer return type");
                }

                if (!has_value.*) {
                    has_value.* = true;
                    inferred.* = ret_type;
                    return;
                }

                const actual = SemType{ .known = ret_type };
                try self.ensureAssignable(inferred.*, actual);
            },
            .if_stmt => |is| {
                _ = try self.inferExprType(is.condition.*);
                try self.pushScope();
                try self.inferReturnTypesInBlock(is.then_body, has_value, has_void, inferred);
                self.popScope();
                for (is.else_ifs) |elif| {
                    _ = try self.inferExprType(elif.condition.*);
                    try self.pushScope();
                    try self.inferReturnTypesInBlock(elif.body, has_value, has_void, inferred);
                    self.popScope();
                }
                if (is.else_body) |else_body| {
                    try self.pushScope();
                    try self.inferReturnTypesInBlock(else_body, has_value, has_void, inferred);
                    self.popScope();
                }
            },
            .while_loop => |wl| {
                _ = try self.inferExprType(wl.condition.*);
                try self.pushScope();
                try self.inferReturnTypesInBlock(wl.body, has_value, has_void, inferred);
                self.popScope();
            },
            .for_loop => |fl| {
                var loop_type: ast.Type = .i32;
                if (fl.iterable.* == .range) {
                    const range = fl.iterable.*.range;
                    const start_t = try self.inferExprType(range.start.*);
                    const end_t = try self.inferExprType(range.end.*);
                    const start_type = try self.rangeEndpointType(start_t);
                    const end_type = try self.rangeEndpointType(end_t);
                    if (!self.typeEquals(start_type, end_type)) {
                        return self.fail("semantic error: for range endpoints must match types");
                    }
                    loop_type = start_type;
                } else {
                    const iter_type = try self.inferExprType(fl.iterable.*);
                    const kt = try self.requireKnownType(iter_type, "semantic error: for loop requires array or slice");
                    switch (kt) {
                        .array => |arr| loop_type = arr.elem.*,
                        .slice => |s| loop_type = s.elem.*,
                        else => return self.fail("semantic error: for loop requires array or slice"),
                    }
                }
                try self.pushScope();
                try self.declareVar(fl.variable, loop_type, true);
                try self.inferReturnTypesInBlock(fl.body, has_value, has_void, inferred);
                self.popScope();
            },
            .try_catch => |tc| {
                const try_type = try self.inferExprType(tc.try_expr.*);
                const eu = try self.requireErrorUnion(try_type, "semantic error: try requires error union");
                try self.pushScope();
                if (tc.catch_var) |name| {
                    try self.declareVar(name, eu.err.*, true);
                }
                try self.inferReturnTypesInBlock(tc.catch_body, has_value, has_void, inferred);
                self.popScope();
            },
            .expr_stmt => |es| {
                _ = try self.inferExprType(es.expr.*);
            },
            .function_def => {}, // ignore nested function definitions for now
            else => {},
        }
    }

    fn containsTryExpr(self: *Analyzer, node: ast.Node) bool {
        return switch (node) {
            .try_expr => true,
            .binary_op => |bin| self.containsTryExpr(bin.left.*) or self.containsTryExpr(bin.right.*),
            .unary_op => |un| self.containsTryExpr(un.operand.*),
            .call => |c| blk: {
                for (c.args) |arg| {
                    if (self.containsTryExpr(arg)) break :blk true;
                }
                break :blk false;
            },
            .array_literal => |arr| blk: {
                for (arr.elements) |elem| {
                    if (self.containsTryExpr(elem)) break :blk true;
                }
                break :blk false;
            },
            .index_expr => |ix| self.containsTryExpr(ix.target.*) or self.containsTryExpr(ix.index.*),
            .index_assign => |ia| self.containsTryExpr(ia.target.*) or self.containsTryExpr(ia.value.*),
            .range => |r| self.containsTryExpr(r.start.*) or self.containsTryExpr(r.end.*),
            else => false,
        };
    }
};
