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

        const value_ptr = try self.allocNode(try self.parseExpr());

        return .{ .set_assign = .{
            .name = var_name,
            .value = value_ptr,
        } };
    }

    fn parseTypedAssign(self: *Parser, name: []const u8) ParseError!ast.Node {
        try self.expect(.kw_as);
        const type_info = try self.parseType();
        try self.expect(.kw_to);

        const value_ptr = try self.allocNode(try self.parseExpr());

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

        const body = try self.parseIndentedBlock(&.{});

        return .{ .function_def = .{
            .name = name,
            .params = params.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .return_type = return_type,
            .body = body,
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

        const value_ptr = try self.allocNode(try self.parseExpr());

        return .{ .return_stmt = .{ .value = value_ptr } };
    }

    fn parseIf(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_if);

        const cond_ptr = try self.allocNode(try self.parseExpr());

        try self.expect(.kw_then);
        self.skipNewlines();

        const then_body = try self.parseIndentedBlock(&.{ .kw_else });

        // Parse else if / else
        var else_ifs: std.ArrayList(ast.ElseIf) = .empty;
        var else_body: ?[]const ast.Node = null;

        while (self.current().tag == .kw_else) {
            self.pos += 1; // consume 'else'

            if (self.current().tag == .kw_if) {
                // else if
                self.pos += 1; // consume 'if'

                const elif_cond_ptr = try self.allocNode(try self.parseExpr());

                try self.expect(.kw_then);
                self.skipNewlines();

                const elif_body = try self.parseIndentedBlock(&.{ .kw_else });

                else_ifs.append(self.allocator, .{
                    .condition = elif_cond_ptr,
                    .body = elif_body,
                }) catch return ParseError.OutOfMemory;
            } else {
                // else
                self.skipNewlines();
                else_body = try self.parseIndentedBlock(&.{});
                break;
            }
        }

        return .{ .if_stmt = .{
            .condition = cond_ptr,
            .then_body = then_body,
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

        const cond_ptr = try self.allocNode(try self.parseExpr());

        self.skipNewlines();

        const body = try self.parseIndentedBlock(&.{});

        return .{ .while_loop = .{
            .condition = cond_ptr,
            .body = body,
        } };
    }

    fn parseForLoop(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_for);

        const var_tok = self.current();
        if (var_tok.tag != .name) return ParseError.UnexpectedToken;
        self.pos += 1;

        try self.expect(.kw_in);

        const iter_ptr = try self.allocNode(try self.parseExpr());

        self.skipNewlines();

        const body = try self.parseIndentedBlock(&.{});

        return .{ .for_loop = .{
            .variable = var_tok.lexeme,
            .iterable = iter_ptr,
            .body = body,
        } };
    }

    fn parseBreak(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_break);

        // Check if there's a break value
        if (self.current().tag == .newline or self.current().tag == .eof) {
            return .{ .break_stmt = .{ .value = null } };
        }

        const value_ptr = try self.allocNode(try self.parseExpr());

        return .{ .break_stmt = .{ .value = value_ptr } };
    }

    fn parseContinue(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_continue);
        return .{ .continue_stmt = .{} };
    }

    fn parseTryCatch(self: *Parser) ParseError!ast.Node {
        try self.expect(.kw_try);

        const try_ptr = try self.allocNode(try self.parseExpr());

        try self.expect(.kw_catch);

        var catch_var: ?[]const u8 = null;
        if (self.current().tag == .name) {
            catch_var = self.current().lexeme;
            self.pos += 1;
        }

        self.skipNewlines();

        const catch_body = try self.parseIndentedBlock(&.{});

        return .{ .try_catch = .{
            .try_expr = try_ptr,
            .catch_var = catch_var,
            .catch_body = catch_body,
        } };
    }

    fn parseExprStmt(self: *Parser) ParseError!ast.Node {
        const expr_ptr = try self.allocNode(try self.parseExpr());
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
            const operand_ptr = try self.allocNode(try self.parseUnary());
            return .{ .unary_op = .{ .op = .negate, .operand = operand_ptr } };
        }
        if (self.current().tag == .kw_not) {
            self.pos += 1;
            const operand_ptr = try self.allocNode(try self.parseUnary());
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

    fn parseIndentedBlock(self: *Parser, stop_tags: []const TokenType) ParseError![]const ast.Node {
        var body: std.ArrayList(ast.Node) = .empty;
        var first_stmt_col: ?usize = null;

        while (self.current().tag != .eof) {
            while (self.current().tag == .newline) {
                self.pos += 1;
            }

            if (self.current().tag == .eof) break;
            if (self.isStopTag(stop_tags, self.current().tag)) break;

            if (first_stmt_col) |first_col| {
                if (self.current().col < first_col) break;
            } else {
                first_stmt_col = self.current().col;
            }

            const stmt = try self.parseStmt();
            body.append(self.allocator, stmt) catch return ParseError.OutOfMemory;
        }

        return body.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
    }

    fn isStopTag(self: *Parser, stop_tags: []const TokenType, tag: TokenType) bool {
        _ = self;
        for (stop_tags) |stop_tag| {
            if (tag == stop_tag) return true;
        }
        return false;
    }

    fn allocNode(self: *Parser, node: ast.Node) ParseError!*ast.Node {
        const node_ptr = self.allocator.create(ast.Node) catch return ParseError.OutOfMemory;
        node_ptr.* = node;
        return node_ptr;
    }

    fn makeBinary(self: *Parser, op: ast.BinaryOp.Op, left: ast.Node, right: ast.Node) ParseError!ast.Node {
        const left_ptr = try self.allocNode(left);
        const right_ptr = try self.allocNode(right);
        return .{ .binary_op = .{
            .op = op,
            .left = left_ptr,
            .right = right_ptr,
        } };
    }
};
