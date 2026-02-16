/// Recursive descent parser for 1im.
/// Converts a token stream into an AST.
const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidCallTarget,
    OutOfMemory,
};

pub const Parser = struct {
    tokens: []const Token,
    pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token) Parser {
        return .{
            .tokens = tokens,
            .pos = 0,
            .allocator = allocator,
        };
    }

    // ── Public API ──────────────────────────────────────────────

    pub fn parse(self: *Parser) ParseError!ast.Node {
        var stmts: std.ArrayList(ast.Node) = .empty;

        while (self.current().tag != .eof) {
            self.skipNewlines();
            if (self.current().tag == .eof) break;

            const stmt = try self.parseStmt();
            stmts.append(self.allocator, stmt) catch return ParseError.OutOfMemory;
        }

        return .{ .program = .{
            .stmts = stmts.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        } };
    }

    /// Report current position for error messages.
    pub fn currentLine(self: *const Parser) usize {
        return self.current().line;
    }

    pub fn currentCol(self: *const Parser) usize {
        return self.current().col;
    }

    // ── Statements ──────────────────────────────────────────────

    fn parseStmt(self: *Parser) ParseError!ast.Node {
        switch (self.current().tag) {
            .kw_set => return self.parseSetOrFunction(),
            .kw_return => return self.parseReturn(),
            .kw_if => return self.parseIf(),
            .kw_loop => return self.parseLoop(),
            .kw_break => return self.parseBreak(),
            .kw_continue => return self.parseContinue(),
            .kw_try => return self.parseTryCatch(),
            else => return self.parseExprStmt(),
        }
    }

    /// Parse `set` statement - could be variable assignment or function definition
    fn parseSetOrFunction(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_set); // consume 'set'

        const name_tok = self.current();
        if (name_tok.tag != .name) return ParseError.UnexpectedToken;
        const var_name = name_tok.lexeme;
        self.pos += 1;

        // Check if it's a function: `set name with...` or `set name as fn`
        if (self.current().tag == .kw_with or (self.current().tag == .kw_as and self.peek(1).tag == .kw_fn)) {
            return self.parseFunctionDef(var_name);
        }

        // Check if it's a typed assignment: `set name as type to value`
        if (self.current().tag == .kw_as) {
            return self.parseTypedAssign(var_name);
        }

        // Regular assignment: `set name to value`
        try self.expect(.kw_to);

        const value = try self.parseExpr();
        const value_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        value_ptr.* = value;

        return .{ .set_assign = .{
            .name = var_name,
            .value = value_ptr,
        } };
    }

    fn parseTypedAssign(self: *Parser, name: []const u8) ParseError!ast.Node {
        try self.expect(.kw_as);
        const type_info = try self.parseType();
        try self.expect(.kw_to);

        const value = try self.parseExpr();
        const value_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        value_ptr.* = value;

        return .{ .typed_assign = .{
            .name = name,
            .type_info = type_info,
            .value = value_ptr,
        } };
    }

    fn parseFunctionDef(self: *Parser, name: []const u8) ParseError!ast.Node {
        var params: std.ArrayList(ast.Param) = .empty;
        var return_type: ?ast.Type = null;

        // Parse parameters if present: `with param1 as type1, param2 as type2`
        if (self.current().tag == .kw_with) {
            self.pos += 1;

            while (true) {
                const param_name_tok = self.current();
                if (param_name_tok.tag != .name) return ParseError.UnexpectedToken;
                self.pos += 1;

                try self.expect(.kw_as);
                const param_type = try self.parseType();

                params.append(self.allocator, .{
                    .name = param_name_tok.lexeme,
                    .type_info = param_type,
                }) catch return ParseError.OutOfMemory;

                if (self.current().tag != .comma) break;
                self.pos += 1; // consume comma
            }
        }

        // Parse return type if present: `returns type`
        if (self.current().tag == .kw_returns) {
            self.pos += 1;
            return_type = try self.parseType();
        }

        // Parse function body (must be on next line, indented)
        self.skipNewlines();

        var body: std.ArrayList(ast.Node) = .empty;
        while (self.current().tag != .eof and self.current().tag != .kw_set and
            self.current().tag != .kw_if and self.current().tag != .kw_loop)
        {
            self.skipNewlines();
            if (self.current().tag == .eof) break;

            // Simple heuristic: if we see a top-level keyword, end the function
            if (self.pos > 0 and self.tokens[self.pos - 1].tag == .newline) {
                if (self.current().tag == .kw_set or self.current().tag == .kw_if or
                    self.current().tag == .kw_loop)
                {
                    break;
                }
            }

            const stmt = try self.parseStmt();
            body.append(self.allocator, stmt) catch return ParseError.OutOfMemory;

            // If we hit a newline followed by dedent (approximated by seeing top-level keyword), break
            if (self.current().tag == .newline) {
                const next_pos = self.pos + 1;
                if (next_pos < self.tokens.len) {
                    const next_tag = self.tokens[next_pos].tag;
                    if (next_tag == .kw_set or next_tag == .kw_if or next_tag == .kw_loop or next_tag == .eof) {
                        self.pos += 1; // consume newline
                        break;
                    }
                }
            }

            if (self.current().tag == .newline) {
                self.pos += 1;
            }
        }

        return .{ .function_def = .{
            .name = name,
            .params = params.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .return_type = return_type,
            .body = body.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        } };
    }

    fn parseType(self: *Parser) ParseError!ast.Type {
        const tok = self.current();
        self.pos += 1;

        return switch (tok.tag) {
            .kw_i8 => .i8,
            .kw_i16 => .i16,
            .kw_i32 => .i32,
            .kw_i64 => .i64,
            .kw_u8 => .u8,
            .kw_u16 => .u16,
            .kw_u32 => .u32,
            .kw_u64 => .u64,
            .kw_f32 => .f32,
            .kw_f64 => .f64,
            .kw_bool => .bool,
            .kw_str => .str,
            .kw_void => .void,
            else => ParseError.UnexpectedToken,
        };
    }

    fn parseReturn(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_return);

        // Check if there's a return value
        if (self.current().tag == .newline or self.current().tag == .eof) {
            return .{ .return_stmt = .{ .value = null } };
        }

        const value = try self.parseExpr();
        const value_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        value_ptr.* = value;

        return .{ .return_stmt = .{ .value = value_ptr } };
    }

    fn parseIf(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_if);

        const condition = try self.parseExpr();
        const cond_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        cond_ptr.* = condition;

        try self.expect(.kw_then);
        self.skipNewlines();

        var then_body: std.ArrayList(ast.Node) = .empty;
        var first_stmt_col: ?usize = null;

        while (self.current().tag != .eof and self.current().tag != .kw_else) {
            // Skip newlines and comments
            while (self.current().tag == .newline) {
                self.pos += 1;
            }

            // Check for else or eof
            if (self.current().tag == .kw_else or self.current().tag == .eof) break;

            // Check for dedent - if less indented than first statement, exit block
            if (first_stmt_col) |first_col| {
                if (self.current().col < first_col) {
                    break;
                }
            } else {
                // First statement in block - record indentation
                first_stmt_col = self.current().col;
            }

            const stmt = try self.parseStmt();
            then_body.append(self.allocator, stmt) catch return ParseError.OutOfMemory;
        }

        // Parse else if / else
        var else_ifs: std.ArrayList(ast.ElseIf) = .empty;
        var else_body: ?[]const ast.Node = null;

        while (self.current().tag == .kw_else) {
            self.pos += 1; // consume 'else'

            if (self.current().tag == .kw_if) {
                // else if
                self.pos += 1; // consume 'if'

                const elif_cond = try self.parseExpr();
                const elif_cond_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
                elif_cond_ptr.* = elif_cond;

                try self.expect(.kw_then);
                self.skipNewlines();

                var elif_body: std.ArrayList(ast.Node) = .empty;
                var elif_first_col: ?usize = null;

                while (self.current().tag != .eof and self.current().tag != .kw_else) {
                    // Skip newlines
                    while (self.current().tag == .newline) {
                        self.pos += 1;
                    }

                    // Check for else or eof
                    if (self.current().tag == .kw_else or self.current().tag == .eof) break;

                    // Check for dedent
                    if (elif_first_col) |first_col| {
                        if (self.current().col < first_col) {
                            break;
                        }
                    } else {
                        elif_first_col = self.current().col;
                    }

                    const stmt = try self.parseStmt();
                    elif_body.append(self.allocator, stmt) catch return ParseError.OutOfMemory;
                }

                else_ifs.append(self.allocator, .{
                    .condition = elif_cond_ptr,
                    .body = elif_body.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
                }) catch return ParseError.OutOfMemory;
            } else {
                // else
                self.skipNewlines();

                var else_stmts: std.ArrayList(ast.Node) = .empty;
                var else_first_col: ?usize = null;

                while (self.current().tag != .eof) {
                    // Skip newlines
                    while (self.current().tag == .newline) {
                        self.pos += 1;
                    }

                    if (self.current().tag == .eof) break;

                    // Check for dedent
                    if (else_first_col) |first_col| {
                        if (self.current().col < first_col) {
                            break;
                        }
                    } else {
                        else_first_col = self.current().col;
                    }

                    const stmt = try self.parseStmt();
                    else_stmts.append(self.allocator, stmt) catch return ParseError.OutOfMemory;
                }

                else_body = else_stmts.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
                break;
            }
        }

        return .{ .if_stmt = .{
            .condition = cond_ptr,
            .then_body = then_body.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .else_ifs = else_ifs.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .else_body = else_body,
        } };
    }

    fn parseLoop(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_loop);

        // Check for while or for
        if (self.current().tag == .kw_while) {
            return self.parseWhileLoop();
        }

        if (self.current().tag == .kw_for) {
            return self.parseForLoop();
        }

        // Infinite loop not implemented yet
        return ParseError.UnexpectedToken;
    }

    fn parseWhileLoop(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_while);

        const condition = try self.parseExpr();
        const cond_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        cond_ptr.* = condition;

        self.skipNewlines();

        var body: std.ArrayList(ast.Node) = .empty;
        var first_stmt_col: ?usize = null;

        while (self.current().tag != .eof) {
            // Skip newlines
            while (self.current().tag == .newline) {
                self.pos += 1;
            }

            if (self.current().tag == .eof) break;

            // Check for dedent - if current statement is less indented than first, exit block
            if (first_stmt_col) |first_col| {
                if (self.current().col < first_col) {
                    break;
                }
            } else {
                // First statement in block - record its indentation
                first_stmt_col = self.current().col;
            }

            const stmt = try self.parseStmt();
            body.append(self.allocator, stmt) catch return ParseError.OutOfMemory;
        }

        return .{ .while_loop = .{
            .condition = cond_ptr,
            .body = body.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        } };
    }

    fn parseForLoop(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_for);

        const var_tok = self.current();
        if (var_tok.tag != .name) return ParseError.UnexpectedToken;
        self.pos += 1;

        try self.expect(.kw_in);

        const iterable = try self.parseExpr();
        const iter_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        iter_ptr.* = iterable;

        self.skipNewlines();

        var body: std.ArrayList(ast.Node) = .empty;
        while (self.current().tag != .eof and self.current().tag != .kw_set and self.current().tag != .kw_loop) {
            if (self.current().tag == .newline) {
                self.pos += 1;
                if (self.current().tag == .kw_set or self.current().tag == .kw_loop or self.current().tag == .eof) break;
                continue;
            }

            const stmt = try self.parseStmt();
            body.append(self.allocator, stmt) catch return ParseError.OutOfMemory;

            if (self.current().tag == .newline) {
                self.pos += 1;
            }
        }

        return .{ .for_loop = .{
            .variable = var_tok.lexeme,
            .iterable = iter_ptr,
            .body = body.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        } };
    }

    fn parseBreak(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_break);

        // Check if there's a break value
        if (self.current().tag == .newline or self.current().tag == .eof) {
            return .{ .break_stmt = .{ .value = null } };
        }

        const value = try self.parseExpr();
        const value_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        value_ptr.* = value;

        return .{ .break_stmt = .{ .value = value_ptr } };
    }

    fn parseContinue(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_continue);
        return .{ .continue_stmt = .{} };
    }

    fn parseTryCatch(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_try);

        const try_expr = try self.parseExpr();
        const try_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        try_ptr.* = try_expr;

        try self.expect(.kw_catch);

        var catch_var: ?[]const u8 = null;
        if (self.current().tag == .name) {
            catch_var = self.current().lexeme;
            self.pos += 1;
        }

        self.skipNewlines();

        var catch_body: std.ArrayList(ast.Node) = .empty;
        while (self.current().tag != .eof and self.current().tag != .kw_set) {
            const stmt = try self.parseStmt();
            catch_body.append(self.allocator, stmt) catch return ParseError.OutOfMemory;
            if (self.current().tag == .newline) self.pos += 1;
            if (self.current().tag == .kw_set) break;
        }

        return .{ .try_catch = .{
            .try_expr = try_ptr,
            .catch_var = catch_var,
            .catch_body = catch_body.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        } };
    }

    fn parseExprStmt(self: *Parser) ParseError!ast.Node {
        const expr = try self.parseExpr();
        const expr_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        expr_ptr.* = expr;
        return .{ .expr_stmt = .{ .expr = expr_ptr } };
    }

    // ── Expressions ─────────────────────────────────────────────
    // Precedence climbing: or < and < comparison < add < mul < unary < postfix < primary

    fn parseExpr(self: *Parser) ParseError!ast.Node {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!ast.Node {
        var left = try self.parseAnd();
        while (self.current().tag == .kw_or) {
            self.pos += 1;
            const right = try self.parseAnd();
            left = try self.makeBinary(.bool_or, left, right);
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!ast.Node {
        var left = try self.parseComparison();
        while (self.current().tag == .kw_and) {
            self.pos += 1;
            const right = try self.parseComparison();
            left = try self.makeBinary(.bool_and, left, right);
        }
        return left;
    }

    fn parseComparison(self: *Parser) ParseError!ast.Node {
        var left = try self.parseAdd();
        const cmp_op: ?ast.BinaryOp.Op = switch (self.current().tag) {
            .eq_eq => .eq,
            .bang_eq => .neq,
            .lt => .lt,
            .lt_eq => .lte,
            .gt => .gt,
            .gt_eq => .gte,
            else => null,
        };
        if (cmp_op) |op| {
            self.pos += 1;
            const right = try self.parseAdd();
            left = try self.makeBinary(op, left, right);
        }
        return left;
    }

    fn parseAdd(self: *Parser) ParseError!ast.Node {
        var left = try self.parseMul();
        while (self.current().tag == .plus or self.current().tag == .minus) {
            const op: ast.BinaryOp.Op = if (self.current().tag == .plus) .add else .sub;
            self.pos += 1;
            const right = try self.parseMul();
            left = try self.makeBinary(op, left, right);
        }
        return left;
    }

    fn parseMul(self: *Parser) ParseError!ast.Node {
        var left = try self.parseUnary();
        while (self.current().tag == .star or self.current().tag == .slash or self.current().tag == .percent) {
            const op: ast.BinaryOp.Op = switch (self.current().tag) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => unreachable,
            };
            self.pos += 1;
            const right = try self.parseUnary();
            left = try self.makeBinary(op, left, right);
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!ast.Node {
        if (self.current().tag == .minus) {
            self.pos += 1;
            const operand = try self.parseUnary();
            const operand_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
            operand_ptr.* = operand;
            return .{ .unary_op = .{ .op = .negate, .operand = operand_ptr } };
        }
        if (self.current().tag == .kw_not) {
            self.pos += 1;
            const operand = try self.parseUnary();
            const operand_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
            operand_ptr.* = operand;
            return .{ .unary_op = .{ .op = .bool_not, .operand = operand_ptr } };
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!ast.Node {
        var node = try self.parsePrimary();

        while (true) {
            if (self.current().tag == .lparen) {
                // Function call
                const callee_name = switch (node) {
                    .variable => |v| v.name,
                    else => return ParseError.InvalidCallTarget,
                };

                self.pos += 1; // consume '('
                var args: std.ArrayList(ast.Node) = .empty;

                if (self.current().tag != .rparen) {
                    const first_arg = try self.parseExpr();
                    args.append(self.allocator, first_arg) catch return ParseError.OutOfMemory;

                    while (self.current().tag == .comma) {
                        self.pos += 1; // consume ','
                        const arg = try self.parseExpr();
                        args.append(self.allocator, arg) catch return ParseError.OutOfMemory;
                    }
                }

                try self.expect(.rparen);

                node = .{ .call = .{
                    .callee = callee_name,
                    .args = args.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
                } };
            } else {
                break;
            }
        }

        return node;
    }

    fn parsePrimary(self: *Parser) ParseError!ast.Node {
        const tok = self.current();

        switch (tok.tag) {
            .int_literal => {
                self.pos += 1;
                const value = std.fmt.parseInt(i64, tok.lexeme, 10) catch 0;
                return .{ .int_literal = .{ .value = value } };
            },
            .float_literal => {
                self.pos += 1;
                const value = std.fmt.parseFloat(f64, tok.lexeme) catch 0.0;
                return .{ .float_literal = .{ .value = value } };
            },
            .string_literal => {
                self.pos += 1;
                return .{ .string_literal = .{ .value = tok.lexeme } };
            },
            .kw_true => {
                self.pos += 1;
                return .{ .bool_literal = .{ .value = true } };
            },
            .kw_false => {
                self.pos += 1;
                return .{ .bool_literal = .{ .value = false } };
            },
            .kw_null => {
                self.pos += 1;
                return .{ .null_literal = .{} };
            },
            .name => {
                self.pos += 1;
                return .{ .variable = .{ .name = tok.lexeme } };
            },
            .lparen => {
                self.pos += 1; // consume '('
                const expr = try self.parseExpr();
                try self.expect(.rparen);
                return expr;
            },
            .eof => return ParseError.UnexpectedEof,
            else => return ParseError.UnexpectedToken,
        }
    }

    // ── Helpers ─────────────────────────────────────────────────

    fn current(self: *const Parser) Token {
        if (self.pos >= self.tokens.len) {
            return .{ .tag = .eof, .lexeme = "", .line = 0, .col = 0 };
        }
        return self.tokens[self.pos];
    }

    fn peek(self: *const Parser, offset: usize) Token {
        const new_pos = self.pos + offset;
        if (new_pos >= self.tokens.len) {
            return .{ .tag = .eof, .lexeme = "", .line = 0, .col = 0 };
        }
        return self.tokens[new_pos];
    }

    fn expect(self: *Parser, tag: TokenType) ParseError!void {
        if (self.current().tag != tag) {
            return ParseError.UnexpectedToken;
        }
        self.pos += 1;
    }

    fn skipNewlines(self: *Parser) void {
        while (self.pos < self.tokens.len and self.tokens[self.pos].tag == .newline) {
            self.pos += 1;
        }
    }

    fn makeBinary(self: *Parser, op: ast.BinaryOp.Op, left: ast.Node, right: ast.Node) ParseError!ast.Node {
        const left_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        left_ptr.* = left;
        const right_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        right_ptr.* = right;
        return .{ .binary_op = .{
            .op = op,
            .left = left_ptr,
            .right = right_ptr,
        } };
    }
};
