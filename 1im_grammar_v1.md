# 1im Language Grammar v1 — Systems Language × Bash Killer

> "Simplicity is prerequisite for reliability." — Edsger Dijkstra
>
> 1im is a statically-typed, AOT-compiled language with natural-language syntax,
> first-class shell operations, C ABI compatibility, and zero hidden allocations.
> It sits where C/Zig meet bash — a single language for both systems programming
> and scripting, compiled to native code via LLVM.

---

## 0. Design Philosophy

1. **One way to say each thing.** No synonyms, no optional filler, deterministic parsing.
2. **No undefined behavior.** Every operation has specified semantics. Integer overflow is defined (wrapping or trap — chosen per-build). Null pointer dereference is a trap.
3. **No hidden costs.** No GC, no implicit allocations, no implicit copies, no implicit function calls. If you didn't write it, it doesn't happen.
4. **Errors are values.** No exceptions. Errors propagate explicitly. Ignoring an error is a compile error.
5. **Shell operations are first-class.** Running processes, piping, file I/O, and globs are language primitives — not library afterthoughts.
6. **Compile fast, run fast.** `1im run script.1im` compiles + caches + executes in one step (like `zig run`). No REPL needed.
7. **C is a friend, not a foe.** Calling C functions and being called by C is trivial. No wrapper generators, no ceremony.

---

## 1. Lexical Structure

### 1.1 Source encoding

Source text is UTF-8. Identifiers are ASCII only.

### 1.2 Identifiers

```
NAME := [A-Za-z_][A-Za-z0-9_]*
```

Reserved: all keywords listed in §2.

### 1.3 Numeric literals

```
INT_DEC   := [0-9][0-9_]*
INT_HEX   := "0x" [0-9A-Fa-f][0-9A-Fa-f_]*
INT_OCT   := "0o" [0-7][0-7_]*
INT_BIN   := "0b" [01][01_]*
FLOAT     := [0-9][0-9_]* "." [0-9][0-9_]* [ ("e"|"E") [+-]? [0-9]+ ]
```

Underscores are visual separators, ignored by the parser: `1_000_000`, `0xFF_AA`.

### 1.4 String literals

```1im
STRING     := '"' { CHAR | ESCAPE | INTERP } '"'
RAW_STRING := 'r"' { any except '"' } '"'
ESCAPE     := "\\" | "\"" | "\n" | "\t" | "\r" | "\0" | "\x" HEX HEX
INTERP     := "{" Expr "}"
```

String interpolation uses `{}` inside double-quoted strings:

```1im
set name to "world"
set msg to "hello {name}, 2+2 is {2 + 2}"
```

Raw strings (`r"..."`) have no escapes and no interpolation.

Multi-line strings:

```1im
set sql to """
    SELECT *
    FROM users
    WHERE id = {user_id}
"""
```

### 1.5 Whitespace and indentation

- Newlines terminate statements (except inside `()`, `[]`, `{}`).
- Indentation is significant. Only spaces allowed (tabs are a compile error).
- Indent width is determined by the first indented line (must be consistent).
- Lexer emits `INDENT` / `DEDENT` tokens.
- Blank lines and comment-only lines are ignored for indentation purposes.
- Line continuation: a trailing `\` joins the next line.

### 1.6 Comments

```
COMMENT      := "#" { any except newline }
DOC_COMMENT  := "##" { any except newline }
```

`##` doc-comments attach to the next declaration and are extractable by tooling.

---

## 2. Keywords

```
# Declarations
set, to, with, as, returns, return

# Control flow
if, then, else, match, loop, while, for, in, break, continue

# Types
struct, enum, union, type

# Memory
defer, allocate, free

# Error handling
try, catch, error, or

# Boolean & null
true, false, null

# Logical
and, or, not

# Modules
import, from, export, pub

# FFI
extern

# Compile-time
comptime

# Shell
run, pipe, env, glob

# Parallel
parallel, await
```

Total: 46 keywords. Each has exactly one meaning.

---

## 3. Type System

### 3.1 Primitive types

```
# Integers (signed)
i8   i16   i32   i64   isize

# Integers (unsigned)
u8   u16   u32   u64   usize

# Floating point
f32   f64

# Other
bool       # true or false
void       # no value (function returns nothing)
noreturn   # function never returns (e.g., exit, infinite loop)
```

### 3.2 Compound types

```
[N]T          # Fixed-size array of N elements of type T (stack-allocated)
[]T           # Slice: pointer + length, does not own memory
[*]T          # Multi-pointer (C-style, no length)
*T            # Single-item pointer (mutable)
*const T      # Single-item pointer (read-only)
?T            # Optional: either a value of T or null
T!E           # Error union: either a value of T or an error of type E
str           # Alias for []const u8 (UTF-8 string slice)
```

### 3.3 Type inference

Types can be inferred from context when unambiguous:

```
set x to 42              # inferred as i64 (default integer)
set y to 3.14            # inferred as f64 (default float)
set name to "hello"      # inferred as str
set flag to true         # inferred as bool
```

Explicit annotation overrides inference:

```
set x as i32 to 42
set ratio as f32 to 3.14
```

### 3.4 Type coercion

No implicit coercions. All conversions are explicit:

```
set x as i32 to 42
set y as i64 to cast(i64, x)     # widening: always safe
set z as i16 to truncate(i16, x) # narrowing: may lose data
set f as f64 to to_float(x)      # int to float
set i as i32 to to_int(f)        # float to int (truncates toward zero)
```

---

## 4. Program Structure

```
Program := { TopLevel NEWLINE } EOF

TopLevel :=
    ImportStmt
  | FuncDef
  | StructDef
  | EnumDef
  | UnionDef
  | TypeAlias
  | ConstDecl
  | ExternDecl
  | ExportDecl
  | Stmt              # Allowed at top-level for script mode
```

### 4.1 Entry point

If a file contains a function named `main`, it is the entry point:

```
set main with args as []str returns u8
    print("hello, 1im")
    return 0
```

Return type `u8` is the exit code (0–255). If main returns `void`, exit code is 0.

If a file has no `main` function, top-level statements execute sequentially (script mode).

This means every 1im file is both a valid script and a valid module.

---

## 5. Declarations & Assignment

### 5.1 Variable declaration + assignment (unified `set`)

```
AssignStmt := "set" LValue "to" Expr
TypedAssign := "set" NAME "as" Type "to" Expr
```

First `set` of a name declares it. Subsequent `set` reassigns.

```
set x to 10          # declaration (inferred i64)
set x to 20          # reassignment
```

### 5.2 Immutable bindings

```
ConstDecl := "set" NAME "as" "const" [ Type ] "to" Expr
```

```
set PI as const f64 to 3.14159265
set MAX as const to 1024          # type inferred
```

Constants must be comptime-known.

### 5.3 Multi-assignment

```
MultiAssignStmt := "set" SetPair { "," SetPair }
SetPair := LValue "to" Expr
```

```
set x to 1, y to 2, z to 3
```

Broadcast (`set a, b to 0`) is **not allowed** — it's ambiguous.

### 5.4 Destructuring

```
DestructStmt := "set" DestructTarget "to" Expr

DestructTarget :=
    "(" NameList ")"                 # tuple/multi-return
  | "{" FieldBindList "}"            # struct fields
```

```
set (x, y) to get_position()
set { name, age } to parse_user(data)
```

### 5.5 LValues

```
LValue := NAME { "." NAME | "[" Expr "]" }
```

---

## 6. Functions

### 6.1 Definition

```
FuncDef := "set" NAME "with" Params "returns" Type NEWLINE INDENT Block DEDENT
         | "set" NAME "with" Params NEWLINE INDENT Block DEDENT
         | "set" NAME "returns" Type NEWLINE INDENT Block DEDENT
         | "set" NAME NEWLINE INDENT Block DEDENT
```

Wait — that last form conflicts with variable declaration. Revised:

```
FuncDef :=
    "set" NAME "with" Params "returns" Type NEWLINE INDENT Block DEDENT
  | "set" NAME "with" Params NEWLINE INDENT Block DEDENT
  | "set" NAME "as" "fn" "returns" Type NEWLINE INDENT Block DEDENT
  | "set" NAME "as" "fn" NEWLINE INDENT Block DEDENT
```

```
Params := Param { "," Param }
Param  := NAME "as" Type [ "to" Expr ]    # optional default value

Block  := { Stmt NEWLINE }

ReturnStmt := "return" [ Expr ]
```

Examples:

```
# Function with params and return type
set add with a as i32, b as i32 returns i32
    return a + b

# No params, explicit return type
set get_version as fn returns str
    return "1.0.0"

# With default parameter
set greet with name as str to "world"
    print("hello {name}")

# Void return (implicit)
set log_msg with msg as str
    print("[LOG] {msg}")
```

### 6.2 Implicit return

If the last statement in a block is an expression, it is the return value:

```
set square with x as i32 returns i32
    x * x
```

If no explicit or implicit return, function returns `void`.

### 6.3 Function types

```
FnType := "fn" "(" [ TypeList ] ")" [ "returns" Type ]
```

```
set callback as fn(i32, i32) returns i32 to add
set transformer as fn(str) returns str
```

### 6.4 Anonymous functions (closures)

```
Lambda := "fn" "(" [ Params ] ")" [ "returns" Type ] NEWLINE INDENT Block DEDENT
        | "fn" "(" [ Params ] ")" Expr
```

```
# Single-expression closure
set doubled to map(numbers, fn(x as i32) x * 2)

# Multi-line closure
set handler to fn(req as Request) returns Response
    set body to parse(req.body)
    respond(200, body)
```

Closures capture by reference. To capture by value, use `copy`:

```
set x to 42
set f to fn() copy(x)    # captures a copy of x
```

---

## 7. Control Flow

### 7.1 Conditionals

```
IfStmt := "if" Expr "then" NEWLINE INDENT Block DEDENT
          { "else" "if" Expr "then" NEWLINE INDENT Block DEDENT }
          [ "else" NEWLINE INDENT Block DEDENT ]
```

```
if x > 0 then
    print("positive")
else if x == 0 then
    print("zero")
else
    print("negative")
```

### 7.2 If-expression (ternary)

```
IfExpr := "if" Expr "then" Expr "else" Expr
```

```
set abs_x to if x >= 0 then x else -x
```

Both branches must have the same type.

### 7.3 Match (exhaustive pattern matching)

```
MatchStmt := "match" Expr NEWLINE INDENT { MatchArm } DEDENT

MatchArm := Pattern "then" NEWLINE INDENT Block DEDENT
           | Pattern "then" Expr NEWLINE

Pattern :=
    Literal
  | NAME                          # bind to variable
  | "_"                           # wildcard
  | EnumVariant [ "(" NameList ")" ]
  | Pattern "," Pattern           # tuple
  | "if" Expr                     # guard
```

```
match status
    200 then print("ok")
    404 then print("not found")
    code if code >= 500 then print("server error: {code}")
    _ then print("unknown")
```

Match is exhaustive: the compiler ensures all cases are covered.

### 7.4 Loops

```
WhileLoop := "loop" "while" Expr NEWLINE INDENT Block DEDENT
ForLoop   := "loop" "for" NAME "in" Expr NEWLINE INDENT Block DEDENT
InfLoop   := "loop" NEWLINE INDENT Block DEDENT

BreakStmt    := "break" [ Expr ]     # break with value
ContinueStmt := "continue"
```

```
# Infinite loop
loop
    set line to try read_line()
    if line == "quit" then
        break

# While loop
loop while connected
    process_events()

# For loop (over iterable)
loop for item in list
    print(item)

# For loop with index (range)
loop for i in 0..10
    print(i)

# Loop as expression (break with value)
set found to loop for item in items
    if item.name == target then
        break item
```

### 7.5 Ranges

```
Range := Expr ".." Expr               # exclusive end
       | Expr "..=" Expr              # inclusive end
```

---

## 8. Expressions

### 8.1 Precedence (highest to lowest)

| Level | Operators                   | Associativity |
| ----- | --------------------------- | ------------- |
| 1     | `.` `[]` `()`               | left          |
| 2     | `not` `-` (unary)           | right         |
| 3     | `*` `/` `%`                 | left          |
| 4     | `+` `-`                     | left          |
| 5     | `<<` `>>`                   | left          |
| 6     | `&` (bitwise and)           | left          |
| 7     | `^` (bitwise xor)           | left          |
| 8     | `\|` (bitwise or)           | left          |
| 9     | `==` `!=` `<` `<=` `>` `>=` | none          |
| 10    | `and`                       | left          |
| 11    | `or`                        | left          |

Comparison operators are **non-chaining**: `a < b < c` is a compile error.
Use `a < b and b < c`.

### 8.2 Grammar

```
Expr := OrExpr

OrExpr  := AndExpr { "or" AndExpr }
AndExpr := CmpExpr { "and" CmpExpr }

CmpExpr := BitOrExpr [ CmpOp BitOrExpr ]
CmpOp   := "==" | "!=" | "<" | "<=" | ">" | ">="

BitOrExpr  := BitXorExpr { "|" BitXorExpr }
BitXorExpr := BitAndExpr { "^" BitAndExpr }
BitAndExpr := ShiftExpr  { "&" ShiftExpr }
ShiftExpr  := AddExpr    { ("<<" | ">>") AddExpr }

AddExpr   := MulExpr   { ("+" | "-") MulExpr }
MulExpr   := UnaryExpr { ("*" | "/" | "%") UnaryExpr }

UnaryExpr := ("not" | "-") UnaryExpr | PostfixExpr

PostfixExpr := Primary { PostfixOp }

PostfixOp :=
    "." NAME
  | "[" Expr "]"
  | "(" [ ArgList ] ")"
  | ".?" NAME                    # optional field access (returns null if null)

ArgList := Expr { "," Expr } [ "," ]    # trailing comma allowed

Primary :=
    INT | FLOAT | STRING | "true" | "false" | "null"
  | NAME
  | "(" Expr ")"
  | ListLit
  | MapLit
  | Lambda
  | IfExpr
  | "try" Expr
  | "comptime" Expr
```

### 8.3 Literals

```
ListLit := "[" [ Expr { "," Expr } [ "," ] ] "]"

MapLit := "{" [ MapEntry { "," MapEntry } [ "," ] ] "}"
MapEntry := Expr ":" Expr

TupleLit := "(" Expr "," Expr { "," Expr } [ "," ] ")"
```

Trailing commas are always allowed in lists, maps, tuples, function args, and params.

---

## 9. Type Definitions

### 9.1 Structs

```
StructDef := "set" NAME "as" "struct" NEWLINE INDENT { FieldDef NEWLINE } DEDENT

FieldDef := NAME "as" Type [ "to" Expr ]     # optional default value
```

```
set Vec3 as struct
    x as f64 to 0.0
    y as f64 to 0.0
    z as f64 to 0.0
```

Construction:

```
set p to Vec3 { x: 1.0, y: 2.0, z: 3.0 }
set origin to Vec3 {}                         # uses defaults
```

### 9.2 Methods

Methods are functions defined inside a struct block with `self` as first param:

```
set Vec3 as struct
    x as f64
    y as f64
    z as f64

    set length with self returns f64
        sqrt(self.x * self.x + self.y * self.y + self.z * self.z)

    set scale with self, factor as f64 returns Vec3
        Vec3 { x: self.x * factor, y: self.y * factor, z: self.z * factor }
```

```
set v to Vec3 { x: 3.0, y: 4.0, z: 0.0 }
set len to v.length()       # 5.0
```

### 9.3 Enums

```
EnumDef := "set" NAME "as" "enum" [ "(" Type ")" ] NEWLINE INDENT { EnumVariant NEWLINE } DEDENT

EnumVariant := NAME [ "to" Expr ]    # explicit discriminant
```

```
set Color as enum
    Red
    Green
    Blue

set HttpStatus as enum(u16)
    Ok to 200
    NotFound to 404
    ServerError to 500
```

### 9.4 Tagged unions

```
UnionDef := "set" NAME "as" "union" NEWLINE INDENT { UnionVariant NEWLINE } DEDENT

UnionVariant := NAME [ "as" Type ]      # variant with or without payload
```

```
set Token as union
    Integer as i64
    Float as f64
    String as str
    Eof                    # no payload

set JsonValue as union
    Null
    Bool as bool
    Number as f64
    String as str
    Array as []JsonValue
    Object as Map(str, JsonValue)
```

Match on tagged unions:

```
match token
    Integer(n) then print("int: {n}")
    Float(f) then print("float: {f}")
    String(s) then print("str: {s}")
    Eof then print("done")
```

### 9.5 Type aliases

```
TypeAlias := "set" NAME "as" "type" Type
```

```
set Byte as type u8
set StringList as type []str
set Handler as type fn(Request) returns Response
```

---

## 10. Memory Management

### 10.1 Principles

- **Stack is default.** All locals live on the stack unless explicitly heap-allocated.
- **No garbage collector.**
- **Allocators are explicit.** Heap allocation goes through an allocator parameter.
- **`defer` for cleanup.** Runs at scope exit, LIFO order.

### 10.2 Stack allocation

```
set point to Vec3 { x: 1.0, y: 2.0, z: 3.0 }       # stack
set buffer as [1024]u8                                 # 1KB on stack
```

### 10.3 Heap allocation

```
set p to allocator.create(Vec3)       # heap allocate one Vec3
defer allocator.destroy(p)            # freed when scope exits

set list to allocator.alloc(u8, 4096) # heap allocate 4096 bytes
defer allocator.free(list)
```

Functions that need heap allocation accept an allocator parameter:

```
set read_all with alloc as Allocator, path as str returns []u8!Error
    set file to try open(path)
    defer file.close()
    return try file.read_all(alloc)
```

### 10.4 Defer

```
DeferStmt := "defer" Stmt
           | "defer" NEWLINE INDENT Block DEDENT
```

```
set file to try open("data.txt")
defer file.close()

# Multi-statement defer
set conn to try connect(db_url)
defer
    conn.commit()
    conn.close()
```

Defers execute in reverse order at scope exit (including error returns).

### 10.5 Pointers

```
set x to 42
set p as *i32 to &x          # address of x
set val to p.*                # dereference (read)
set p.* to 100               # dereference (write), x is now 100
```

Null pointers:

```
set p as ?*i32 to null        # optional pointer — can be null
set p as *i32 to &x           # non-optional pointer — can never be null
```

---

## 11. Error Handling

### 11.1 Error type

Errors are a built-in tagged union, not exceptions:

```
set FileError as enum
    NotFound
    PermissionDenied
    IoError
```

### 11.2 Error union return type

```
# Function that can fail
set read_file with path as str returns str!FileError
    if not exists(path) then
        return error.NotFound
    # ...
```

`T!E` means "either T or an error of type E".

### 11.3 `try` — propagate errors

```
set data to try read_file("config.txt")
# If read_file returns error, this function immediately returns that error.
# Otherwise, data is the unwrapped str value.
```

`try` can only be used in functions that also return an error union.

### 11.4 `catch` — handle errors

```
set data to read_file("config.txt") catch "default content"

set data to read_file("config.txt") catch err
    match err
        FileError.NotFound then "default"
        _ then return error.Fatal
```

### 11.5 The `must` rule

If a function returns an error union and the caller neither `try`s nor `catch`es,
it is a **compile error**. Errors cannot be silently ignored.

```
read_file("config.txt")   # COMPILE ERROR: unhandled error union
```

---

## 12. Shell & Process Operations (The Bash Killer)

This is 1im's differentiator. Shell operations are first-class language constructs,
not library calls wrapped in strings.

### 12.1 Running commands

```
RunExpr := "run" CommandExpr [ PipeChain ] [ Redirect ]
```

```
# Simple command
run "ls -la"

# Capture output
set output to run "ls -la"                    # returns str!ShellError

# With arguments (safe, no injection)
set files to run "find" with args ["/tmp", "-name", "*.log"]

# Error handling
set result to try run "make build"
```

`run` returns `str!ShellError`. The output is captured as a string.
If the process exits non-zero, it returns `error.ExitCode(N)`.

### 12.2 Piping

```
PipeChain := "|" CommandExpr { "|" CommandExpr }
```

```
set count to try run "ls src/" | "grep .1im" | "wc -l"

# Is equivalent to running a pipeline where stdout of each process
# feeds into stdin of the next. All processes run concurrently.
```

### 12.3 Redirection

```
Redirect :=
    ">" Expr          # stdout to file (overwrite)
  | ">>" Expr         # stdout to file (append)
  | "2>" Expr         # stderr to file
  | "<" Expr          # stdin from file
```

```
run "ls -la" > "listing.txt"
run "make build" 2> "errors.log"
run "sort" < "input.txt" > "sorted.txt"
```

### 12.4 Environment variables

```
set path to env("PATH")                # read env var, returns ?str
set env "MY_VAR" to "my_value"         # set env var for this process
set env "DEBUG" to null                # unset env var
```

### 12.5 Glob patterns

```
GlobExpr := "glob" STRING
```

```
set sources to glob "src/**/*.1im"         # returns []str
set configs to glob "/etc/*.conf"

loop for file in glob "*.log"
    run "gzip" with args [file]
```

### 12.6 File operations (built-in, not library)

```
# Read entire file
set content to try read_file("config.txt")

# Write file
try write_file("output.txt", content)

# Append
try append_file("log.txt", "new line\n")

# Check existence
if exists("config.txt") then
    set cfg to try read_file("config.txt")

# File metadata
set info to try stat("myfile.txt")
print("size: {info.size}, modified: {info.modified}")

# Directory operations
try mkdir("build")
try mkdir_all("build/debug/obj")

loop for entry in try read_dir("src/")
    print("{entry.name} is_dir:{entry.is_dir}")
```

### 12.7 Process control

```
# Run in background
set proc to spawn "long-running-task"
# ... do other work ...
set result to try proc.wait()

# Run with timeout
set output to try run "slow-command" with timeout 5000    # 5 seconds

# Run with custom environment
set output to try run "my-tool" with env { "DEBUG": "1", "PORT": "8080" }
```

### 12.8 Exit

```
exit               # exit with code 0
exit with 1        # exit with code 1
```

### 12.9 Script mode example — a build script

```
#!/usr/bin/env 1im run
## build.1im — project build script

set src to glob "src/**/*.c"
set obj_dir to "build/obj"

try mkdir_all(obj_dir)

loop for file in src
    set obj to "{obj_dir}/{basename(file)}.o"
    try run "gcc -c -O2 -o {obj} {file}"
    print("compiled {file}")

set objects to glob "{obj_dir}/*.o"
set obj_args to join(objects, " ")
try run "gcc -o build/myapp {obj_args}"

print("build complete")
```

Compare to the bash equivalent — same length, but type-safe, with real error handling,
string interpolation, and no quoting nightmares.

### 12.10 Structured Result Parsing (Typed Unix)

The fundamental problem with bash: every command returns a string, and you parse
it with `awk`, `sed`, `cut`, `grep` — fragile, unreadable, breaks across platforms.

1im solves this with **typed parsers** for common Unix operations. Instead of
running `ls` and parsing its output, you call a built-in that returns a struct.

#### 12.10.1 Process information

```
# Instead of: ps aux | grep nginx | awk '{print $2}'
set procs to try ps()                        # returns []Process!ShellError

set Process as struct
    pid as u32
    ppid as u32
    user as str
    cpu as f32
    mem as f32
    vsz as u64
    rss as u64
    tty as ?str
    state as str
    start as str
    time as str
    command as str

# Filter in 1im — type-safe, no regex
loop for p in procs
    if p.command.contains("nginx") then
        print("nginx pid: {p.pid}, mem: {p.mem}%")

# Kill by structured query
loop for p in try ps() catch []
    if p.user == "nobody" and p.cpu > 90.0 then
        try run "kill" with args [to_str(p.pid)]
```

#### 12.10.2 Filesystem listing

```
# Instead of: ls -la | awk ...
set entries to try ls("/var/log")            # returns []DirEntry!ShellError

set DirEntry as struct
    name as str
    path as str             # full path
    size as u64
    permissions as u16      # octal mode
    owner as str
    group as str
    modified as Timestamp
    is_dir as bool
    is_symlink as bool
    link_target as ?str     # if symlink

# Find large log files — no awk needed
loop for f in try ls("/var/log")
    if not f.is_dir and f.size > 100 * 1024 * 1024 then
        print("{f.name}: {f.size / 1024 / 1024}MB")
```

#### 12.10.3 Disk usage

```
# Instead of: df -h | tail -n +2 | awk '{print $1, $5}'
set disks to try df()                        # returns []DiskInfo!ShellError

set DiskInfo as struct
    filesystem as str
    mount as str
    total as u64            # bytes
    used as u64
    available as u64
    use_percent as f32

loop for d in try df()
    if d.use_percent > 90.0 then
        print("WARNING: {d.mount} is {d.use_percent}% full")
```

#### 12.10.4 Network

```
# Instead of: netstat -tlnp | grep LISTEN | awk ...
set sockets to try netstat()                 # returns []SocketInfo!ShellError

set SocketInfo as struct
    proto as str            # "tcp", "udp", "tcp6"
    local_addr as str
    local_port as u16
    remote_addr as ?str
    remote_port as ?u16
    state as str            # "LISTEN", "ESTABLISHED", etc.
    pid as ?u32
    process as ?str

# Find what's listening on port 8080
loop for s in try netstat()
    if s.local_port == 8080 and s.state == "LISTEN" then
        print("port 8080: pid {s.pid} ({s.process})")

# DNS lookup — structured, not string parsing
set records to try dns_lookup("example.com")  # returns []DnsRecord!ShellError

set DnsRecord as struct
    name as str
    record_type as str      # "A", "AAAA", "CNAME", "MX", etc.
    value as str
    ttl as u32
```

#### 12.10.5 User and group info

```
# Instead of: cat /etc/passwd | grep username | cut -d: -f3
set user to try whoami()                     # returns UserInfo!ShellError

set UserInfo as struct
    name as str
    uid as u32
    gid as u32
    home as str
    shell as str
    groups as []str

# All users
set users to try get_users()                 # returns []UserInfo!ShellError

loop for u in try get_users()
    if u.uid >= 1000 then
        print("human user: {u.name} (uid {u.uid})")
```

#### 12.10.6 System information

```
set sys to try sysinfo()                     # returns SystemInfo!ShellError

set SystemInfo as struct
    hostname as str
    os as str               # "linux", "macos", "freebsd"
    arch as str             # "x86_64", "aarch64"
    kernel as str           # "6.1.0-generic"
    uptime as u64           # seconds
    cpu_count as u32
    total_mem as u64        # bytes
    free_mem as u64
    load_avg as [3]f64      # 1min, 5min, 15min

if sys.load_avg[0] > cast(f64, sys.cpu_count) then
    print("system overloaded: load {sys.load_avg[0]} on {sys.cpu_count} cores")
```

#### 12.10.7 Package / service management (platform-aware)

```
# Service control — abstracts systemd/launchd/rc
set svc to try service_status("nginx")       # returns ServiceInfo!ShellError

set ServiceInfo as struct
    name as str
    state as str            # "running", "stopped", "failed"
    pid as ?u32
    enabled as bool         # starts on boot?
    uptime as ?u64          # seconds since started

if svc.state != "running" then
    try service_start("nginx")
```

#### 12.10.8 The `parse` keyword — escape hatch for custom commands

For commands without built-in parsers, `parse` turns raw output into structured data:

```
ParseExpr := "parse" Type "from" RunExpr [ "with" ParseOpts ]
```

```
# Parse CSV-like output
set GitLog as struct
    hash as str
    author as str
    date as str
    message as str

set commits to parse []GitLog from run "git log --format=%H|%an|%ad|%s -10" with
    delimiter "|"
    line_split "\n"
    skip_empty true

loop for c in commits
    print("{c.hash[0..8]} {c.author}: {c.message}")
```

```
# Parse key-value output (like /proc files, config files)
set cfg to parse Map(str, str) from run "sysctl -a" with
    delimiter " = "
    line_split "\n"

print("max open files: {cfg["kern.maxfiles"]}")
```

```
# Parse JSON output from modern CLI tools
set pods to parse []KubePod from run "kubectl get pods -o json" with format "json"

# Parse columns (fixed-width or whitespace-separated)
set mounts to parse []MountInfo from run "mount" with
    columns ["device", "on", "mountpoint", "type", "fstype", "options"]
    format "columns"
```

#### 12.10.9 Platform abstraction

All built-in parsers work cross-platform. Internally:
- On Linux: reads `/proc`, calls syscalls directly where possible
- On macOS: uses `sysctl`, `diskutil`, `launchctl`
- On FreeBSD: appropriate equivalents

The structs are the same regardless of OS. Platform-specific fields are `?T` (optional)
when not available everywhere.

```
# This works on Linux, macOS, and FreeBSD:
set info to try sysinfo()
print("running on {info.os}/{info.arch}, kernel {info.kernel}")

set disks to try df()
loop for d in disks
    if d.use_percent > 80.0 then
        print("low space: {d.mount}")
```

No `uname -s | case ... esac` gymnastics. No platform `if` blocks for basic ops.

#### 12.10.10 Why this matters

Bash script for "find processes using >1GB memory":
```bash
ps aux | awk 'NR>1 && $6>1048576 {printf "%s (pid %s): %dMB\n", $11, $2, $6/1024}'
```

1im equivalent:
```
loop for p in try ps()
    if p.rss > 1024 * 1024 * 1024 then
        print("{p.command} (pid {p.pid}): {p.rss / 1024 / 1024}MB")
```

The 1im version is:
- **Type-safe** — `p.rss` is `u64`, not a substring of a line
- **Readable** — no positional `$6` magic numbers
- **Portable** — same code on Linux/macOS
- **Error-handled** — `try` propagates failures
- **Fast** — compiled native code, syscalls not subprocess spawning
- **Discoverable** — IDE autocomplete on struct fields

---

## 13. C Foreign Function Interface

### 13.1 Declaring external C functions

```
ExternDecl := "extern" [ STRING ] "set" NAME "with" Params "returns" Type
            | "extern" [ STRING ] "set" NAME "as" Type
```

```
extern "C" set printf with fmt as *const u8, ... returns i32
extern "C" set malloc with size as usize returns ?*void
extern "C" set free with ptr as *void

extern "C" set errno as i32    # external variable
```

If the ABI string is omitted, `"C"` is assumed:

```
extern set puts with s as *const u8 returns i32
```

### 13.2 Using C functions

```
printf("hello %s, you are %d years old\n", name.ptr, age)

set mem to malloc(1024) catch
    exit with 1
defer free(mem)
```

### 13.3 Exporting 1im functions for C

```
export "C" set my_callback with x as i32 returns i32
    return x * 2
```

This generates a function with C calling convention and no name mangling.

### 13.4 C header import (future / tooling)

```
import @cImport("stdio.h") as stdio
stdio.printf("hello\n")
```

This is a comptime operation that parses C headers (like Zig's `@cImport`).
Deferred to v1+ tooling.

### 13.5 Linking

```
# In build.1im:
set exe to build.add_executable("myapp", glob "src/**/*.1im")
exe.link_library("c")             # libc
exe.link_library("SDL2")          # system library
exe.link_object("legacy.o")       # precompiled object
```

---

## 14. Compile-Time Evaluation

### 14.1 Comptime values

```
set MAX_SIZE as comptime to 4096
set TABLE as comptime to build_lookup_table()
```

`comptime` values are evaluated at compile time and inlined.

### 14.2 Comptime functions

Any function can be called at comptime if it doesn't perform I/O or use pointers:

```
set fibonacci with n as i64 returns i64
    if n <= 1 then return n
    return fibonacci(n - 1) + fibonacci(n - 2)

set FIB_20 as comptime to fibonacci(20)    # computed at compile time
```

### 14.3 Comptime types (generics)

Types are first-class comptime values:

```
set Array with comptime T as type, comptime N as usize returns type
    return struct
        data as [N]T
        len as usize to 0

        set push with self, item as T
            self.data[self.len] = item
            set self.len to self.len + 1

set IntArray to Array(i32, 100)
set buf to IntArray {}
buf.push(42)
```

This replaces both C macros/templates and Zig's comptime generics with
natural-language syntax.

---

## 15. Modules & Imports

### 15.1 File = module

Each `.1im` file is a module. The filename is the module name.

### 15.2 Import syntax

```
ImportStmt :=
    "import" ImportPath [ "as" NAME ]
  | "from" ImportPath "import" NameImportList

ImportPath := STRING | NAME { "." NAME }

NameImportList := NameImport { "," NameImport }
NameImport := NAME [ "as" NAME ]
```

```
import std.fs                          # import module, access as fs.read_file(...)
import std.fs as file_system           # rename
from std.fs import read_file, stat     # import specific names
from std.fs import read_file as rf     # rename imported name

import "vendor/lib.1im" as vendor_lib  # path-based import
```

### 15.3 Visibility

All declarations are module-private by default. Use `pub` to export:

```
pub set Vec3 as struct
    pub x as f64
    pub y as f64
    pub z as f64

    pub set length with self returns f64
        sqrt(self.x * self.x + self.y * self.y + self.z * self.z)

    # Private helper — not accessible outside module
    set normalize_internal with self returns Vec3
        # ...
```

---

## 16. Parallel Execution

### 16.1 Parallel expression

```
ParallelExpr := "parallel" CallExpr { "," CallExpr }
```

```
set (users, posts) to parallel fetch_users(), fetch_posts()
```

- All calls execute concurrently.
- Execution joins (waits for all) before continuing.
- If any call returns an error, all others are cancelled (fail-fast) and the error propagates.
- Number of LHS bindings must equal number of calls.

### 16.2 Spawn / await (for more control)

```
set task to spawn fetch_data(url)
# ... do other work ...
set result to try await task
```

---

## 17. Operator Overloading — Not Supported

No operator overloading. `+` means numeric addition, period.
This prevents "clever" code and keeps the language simple to reason about.

Use named methods instead:

```
set result to vec_a.add(vec_b)
```

---

## 18. Disallowed in v0/v1

- **Exceptions.** Errors are values. No stack unwinding.
- **Operator overloading.** See §17.
- **Inheritance / classes.** Use structs + composition.
- **Null for non-optional types.** `*T` cannot be null; use `?*T`.
- **Implicit type coercion.** All conversions explicit.
- **Global mutable state.** Module-level variables must be `const` or `comptime`.
- **Macros (text-based).** Use `comptime` functions instead.
- **Multiple return via tuples.** Use named structs or destructure.
- **Variadic functions** (except `extern "C"`).
- **`goto`.**

---

## 19. Standard Library Outline

```
std.io        # print, read_line, stdin, stdout, stderr
std.fs        # read_file, write_file, stat, read_dir, glob, mkdir
std.os        # env, exit, args, spawn, run
std.mem       # Allocator, page_allocator, arena_allocator
std.str       # split, join, trim, contains, replace, starts_with
std.math      # sqrt, abs, sin, cos, pow, min, max
std.fmt       # format (used by string interpolation)
std.net       # tcp, udp, http (later)
std.json      # parse, stringify (later)
std.testing   # assert, expect, test runner
std.time      # now, sleep, Timer
```

---

## 20. Build System

1im builds itself. No Makefiles, no CMake:

```
## build.1im
import std.build

set main with b as build.Builder
    set exe to b.add_executable("myapp")
    exe.add_sources(glob "src/**/*.1im")
    exe.link_library("c")
    exe.link_library("SDL2")
    exe.set_optimization(.release_fast)
```

```sh
$ 1im build              # compile
$ 1im run src/main.1im   # compile + run (cached)
$ 1im test               # run tests
$ 1im fmt                # format source
```

---

## 21. Testing

```
## math_test.1im
import std.testing as t

set test_addition as test
    t.expect(add(2, 3) == 5)
    t.expect(add(-1, 1) == 0)

set test_division_by_zero as test
    set result to divide(10, 0)
    t.expect(result is error)
    t.expect(result.err == MathError.DivisionByZero)
```

Tests are functions annotated with `as test`. They are compiled and run by `1im test`.

---

## 22. Full Example — HTTP Fetch Script

```
#!/usr/bin/env 1im run
## fetch.1im — Fetch URLs and report status

set urls to [
    "https://example.com",
    "https://httpbin.org/status/200",
    "https://httpbin.org/status/404",
]

loop for url in urls
    set response to run "curl" with args ["-s", "-o", "/dev/null", "-w", "%{http_code}", url]
    match response
        code if code == "200" then print("[OK]  {url}")
        code if code == "404" then print("[ERR] {url} — not found")
        code then print("[???] {url} — status {code}")
    catch err
        print("[FAIL] {url} — {err}")
```

---

## 23. Full Example — Systems Code with C Interop

```
## png_reader.1im — Read PNG dimensions via libpng (C library)

extern set png_sig_cmp with sig as *const u8, start as usize, count as usize returns i32
extern set fopen with path as *const u8, mode as *const u8 returns ?*void
extern set fclose with fp as *void returns i32
extern set fread with buf as *void, size as usize, count as usize, fp as *void returns usize

set main with args as []str returns u8
    if args.len < 2 then
        print("usage: png_reader <file>")
        return 1

    set fp to fopen(args[1].ptr, "rb".ptr) catch
        print("cannot open file")
        return 1
    defer fclose(fp)

    set header as [8]u8
    fread(&header, 1, 8, fp)

    if png_sig_cmp(&header, 0, 8) != 0 then
        print("not a PNG file")
        return 1

    print("valid PNG file: {args[1]}")
    return 0
```

---

End of 1im Grammar v1.

The language where `set output to try run "ls" | "grep .txt"` compiles
to a native binary faster than the bash script it replaces.
