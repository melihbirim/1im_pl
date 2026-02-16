/// AST node types for the 1im language.
/// Uses Zig tagged unions for type-safe tree representation.
pub const Node = union(enum) {
    program: Program,
    set_assign: SetAssign,
    typed_assign: TypedAssign,
    function_def: FunctionDef,
    return_stmt: ReturnStmt,
    if_stmt: IfStmt,
    while_loop: WhileLoop,
    for_loop: ForLoop,
    break_stmt: BreakStmt,
    continue_stmt: ContinueStmt,
    try_catch: TryCatch,
    expr_stmt: ExprStmt,
    call: Call,
    int_literal: IntLiteral,
    float_literal: FloatLiteral,
    string_literal: StringLiteral,
    bool_literal: BoolLiteral,
    null_literal: NullLiteral,
    variable: Variable,
    binary_op: BinaryOp,
    unary_op: UnaryOp,
};

pub const Program = struct {
    stmts: []const Node,
};

/// `set <name> to <expr>`
pub const SetAssign = struct {
    name: []const u8,
    value: *const Node,
};

/// `set <name> as <type> to <expr>`
pub const TypedAssign = struct {
    name: []const u8,
    type_info: Type,
    value: *const Node,
};

/// Function parameter
pub const Param = struct {
    name: []const u8,
    type_info: Type,
};

/// `set <name> with <params> returns <type> \n <body>`
pub const FunctionDef = struct {
    name: []const u8,
    params: []const Param,
    return_type: ?Type, // null for void
    body: []const Node,
};

/// `return <expr>`
pub const ReturnStmt = struct {
    value: ?*const Node, // null for void return
};

/// `if <cond> then\n<body>\n[else if...]\n[else\n<body>]`
pub const IfStmt = struct {
    condition: *const Node,
    then_body: []const Node,
    else_ifs: []const ElseIf,
    else_body: ?[]const Node,
};

pub const ElseIf = struct {
    condition: *const Node,
    body: []const Node,
};

/// `loop while <cond>\n<body>`
pub const WhileLoop = struct {
    condition: *const Node,
    body: []const Node,
};

/// `loop for <var> in <iter>\n<body>`
pub const ForLoop = struct {
    variable: []const u8,
    iterable: *const Node,
    body: []const Node,
};

/// `break [<expr>]`
pub const BreakStmt = struct {
    value: ?*const Node, // for break with value
};

/// `continue`
pub const ContinueStmt = struct {};

/// `try <expr> catch <var>\n<body>`
pub const TryCatch = struct {
    try_expr: *const Node,
    catch_var: ?[]const u8,
    catch_body: []const Node,
};

/// Expression used as a statement (e.g., a function call)
pub const ExprStmt = struct {
    expr: *const Node,
};

/// Function call: `<callee>(<args>)`
pub const Call = struct {
    callee: []const u8,
    args: []const Node,
};

pub const IntLiteral = struct {
    value: i64,
};

pub const FloatLiteral = struct {
    value: f64,
};

pub const StringLiteral = struct {
    value: []const u8,
};

pub const BoolLiteral = struct {
    value: bool,
};

pub const NullLiteral = struct {};

pub const Variable = struct {
    name: []const u8,
};

pub const BinaryOp = struct {
    op: Op,
    left: *const Node,
    right: *const Node,

    pub const Op = enum {
        add,
        sub,
        mul,
        div,
        mod,
        eq,
        neq,
        lt,
        lte,
        gt,
        gte,
        bool_and,
        bool_or,
    };
};

pub const UnaryOp = struct {
    op: Op,
    operand: *const Node,

    pub const Op = enum {
        negate,
        bool_not,
    };
};

/// Type information
pub const Type = union(enum) {
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
    bool,
    str,
    void,

    pub fn toCString(self: Type) []const u8 {
        return switch (self) {
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
            .void => "void",
        };
    }

    pub fn formatSpecifier(self: Type) []const u8 {
        return switch (self) {
            .i8, .i16, .i32 => "%d",
            .i64 => "%" ++ "PRId64",
            .u8, .u16, .u32 => "%u",
            .u64 => "%" ++ "PRIu64",
            .f32, .f64 => "%f",
            .bool => "%d",
            .str => "%s",
            .void => "",
        };
    }
};
