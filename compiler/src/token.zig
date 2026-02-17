const std = @import("std");

pub const TokenType = enum {
    // Keywords
    kw_set,
    kw_to,
    kw_with,
    kw_as,
    kw_returns,
    kw_return,
    kw_if,
    kw_then,
    kw_else,
    kw_loop,
    kw_while,
    kw_for,
    kw_in,
    kw_break,
    kw_continue,
    kw_import,
    kw_from,
    kw_parallel,
    kw_fun,
    kw_true,
    kw_false,
    kw_null,
    kw_and,
    kw_or,
    kw_not,
    kw_try,
    kw_catch,
    kw_fn,

    // Type keywords
    kw_i8,
    kw_i16,
    kw_i32,
    kw_i64,
    kw_u8,
    kw_u16,
    kw_u32,
    kw_u64,
    kw_f32,
    kw_f64,
    kw_bool,
    kw_str,
    kw_void,

    // Literals
    int_literal,
    float_literal,
    string_literal,

    // Identifier
    name,

    // Punctuation
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    comma,
    dot,
    dot_dot,
    dot_dot_eq,
    colon,

    // Operators
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    eq_eq,
    bang_eq,
    lt,
    lt_eq,
    gt,
    gt_eq,

    // Structure
    newline,
    eof,

    pub fn name_str(self: TokenType) []const u8 {
        return @tagName(self);
    }
};

pub const Token = struct {
    tag: TokenType,
    lexeme: []const u8,
    line: usize,
    col: usize,

    pub fn format(
        self: Token,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}(\"{s}\" L{d}:{d})", .{
            self.tag.name_str(),
            self.lexeme,
            self.line,
            self.col,
        });
    }
};
