const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;

pub const LexerError = error{
    UnexpectedCharacter,
    UnterminatedString,
    OutOfMemory,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: usize,
    col: usize,
    tokens: std.ArrayList(Token),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
            .tokens = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.tokens.deinit(self.allocator);
    }

    pub fn tokenize(self: *Lexer) LexerError![]const Token {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];

            // Skip spaces (not newlines)
            if (c == ' ') {
                self.advance();
                continue;
            }

            // Skip carriage return
            if (c == '\r') {
                self.advance();
                continue;
            }

            // Skip tabs (technically forbidden in 1im, but let's be lenient for now)
            if (c == '\t') {
                self.advance();
                continue;
            }

            // Comments
            if (c == '#') {
                self.skipComment();
                continue;
            }

            // Newlines
            if (c == '\n') {
                try self.addToken(.newline, "\n");
                self.pos += 1;
                self.line += 1;
                self.col = 1;
                continue;
            }

            // Strings
            if (c == '"') {
                try self.readString();
                continue;
            }

            // Numbers
            if (std.ascii.isDigit(c)) {
                try self.readNumber();
                continue;
            }

            // Identifiers and keywords
            if (std.ascii.isAlphabetic(c) or c == '_') {
                try self.readName();
                continue;
            }

            // Two-char operators (check before single-char)
            if (c == '=' and self.peek(1) == '=') {
                const start_col = self.col;
                try self.addTokenAt(.eq_eq, "==", start_col);
                self.advance();
                self.advance();
                continue;
            }
            if (c == '!' and self.peek(1) == '=') {
                const start_col = self.col;
                try self.addTokenAt(.bang_eq, "!=", start_col);
                self.advance();
                self.advance();
                continue;
            }
            if (c == '<' and self.peek(1) == '=') {
                const start_col = self.col;
                try self.addTokenAt(.lt_eq, "<=", start_col);
                self.advance();
                self.advance();
                continue;
            }
            if (c == '>' and self.peek(1) == '=') {
                const start_col = self.col;
                try self.addTokenAt(.gt_eq, ">=", start_col);
                self.advance();
                self.advance();
                continue;
            }

            // Single-char tokens
            const single_tag: ?TokenType = switch (c) {
                '(' => .lparen,
                ')' => .rparen,
                '[' => .lbracket,
                ']' => .rbracket,
                '{' => .lbrace,
                '}' => .rbrace,
                ',' => .comma,
                '.' => .dot,
                ':' => .colon,
                '+' => .plus,
                '-' => .minus,
                '*' => .star,
                '/' => .slash,
                '%' => .percent,
                '<' => .lt,
                '>' => .gt,
                else => null,
            };

            if (single_tag) |tag| {
                try self.addToken(tag, self.source[self.pos .. self.pos + 1]);
                self.advance();
                continue;
            }

            return LexerError.UnexpectedCharacter;
        }

        try self.addToken(.eof, "");
        return self.tokens.items;
    }

    fn advance(self: *Lexer) void {
        self.pos += 1;
        self.col += 1;
    }

    fn peek(self: *const Lexer, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx < self.source.len) return self.source[idx];
        return null;
    }

    fn addToken(self: *Lexer, tag: TokenType, lexeme: []const u8) LexerError!void {
        try self.addTokenAt(tag, lexeme, self.col);
    }

    fn addTokenAt(self: *Lexer, tag: TokenType, lexeme: []const u8, col: usize) LexerError!void {
        self.tokens.append(self.allocator, .{
            .tag = tag,
            .lexeme = lexeme,
            .line = self.line,
            .col = col,
        }) catch return LexerError.OutOfMemory;
    }

    fn skipComment(self: *Lexer) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.advance();
        }
    }

    fn readString(self: *Lexer) LexerError!void {
        const start_col = self.col;
        self.advance(); // skip opening "
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\\') self.advance(); // skip escape
            self.advance();
        }
        if (self.pos >= self.source.len) return LexerError.UnterminatedString;
        const lexeme = self.source[start..self.pos];
        try self.addTokenAt(.string_literal, lexeme, start_col);
        self.advance(); // skip closing "
    }

    fn readNumber(self: *Lexer) LexerError!void {
        const start = self.pos;
        const start_col = self.col;
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.advance();
        }
        // Check for float
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.advance();
            while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
                self.advance();
            }
            try self.addTokenAt(.float_literal, self.source[start..self.pos], start_col);
        } else {
            try self.addTokenAt(.int_literal, self.source[start..self.pos], start_col);
        }
    }

    fn readName(self: *Lexer) LexerError!void {
        const start = self.pos;
        const start_col = self.col;
        while (self.pos < self.source.len and
            (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_'))
        {
            self.advance();
        }
        const lexeme = self.source[start..self.pos];
        const tag = keyword_map.get(lexeme) orelse TokenType.name;
        try self.addTokenAt(tag, lexeme, start_col);
    }

    const keyword_map = std.StaticStringMap(TokenType).initComptime(.{
        .{ "set", .kw_set },
        .{ "to", .kw_to },
        .{ "with", .kw_with },
        .{ "as", .kw_as },
        .{ "returns", .kw_returns },
        .{ "return", .kw_return },
        .{ "if", .kw_if },
        .{ "then", .kw_then },
        .{ "else", .kw_else },
        .{ "loop", .kw_loop },
        .{ "while", .kw_while },
        .{ "for", .kw_for },
        .{ "in", .kw_in },
        .{ "break", .kw_break },
        .{ "continue", .kw_continue },
        .{ "import", .kw_import },
        .{ "from", .kw_from },
        .{ "parallel", .kw_parallel },
        .{ "true", .kw_true },
        .{ "false", .kw_false },
        .{ "null", .kw_null },
        .{ "and", .kw_and },
        .{ "or", .kw_or },
        .{ "not", .kw_not },
        .{ "try", .kw_try },
        .{ "catch", .kw_catch },
        .{ "fn", .kw_fn },
        .{ "i8", .kw_i8 },
        .{ "i16", .kw_i16 },
        .{ "i32", .kw_i32 },
        .{ "i64", .kw_i64 },
        .{ "u8", .kw_u8 },
        .{ "u16", .kw_u16 },
        .{ "u32", .kw_u32 },
        .{ "u64", .kw_u64 },
        .{ "f32", .kw_f32 },
        .{ "f64", .kw_f64 },
        .{ "bool", .kw_bool },
        .{ "str", .kw_str },
        .{ "void", .kw_void },
    });
};
