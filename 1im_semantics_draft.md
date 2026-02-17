# 1im Semantics Draft (Phase 1.5)

This is a working draft that defines **core language semantics** needed before expanding features.
It prioritizes safety, predictability, and a small, coherent core.

Status: Draft (subject to iteration with tests).

## 1. Scoping and Binding

- **Lexical scoping**: names resolve to the nearest enclosing scope.
- **Block scopes**: every `if`, `else`, `loop`, `try/catch`, and function body introduces a new scope.
- **Declaration vs assignment**:
  - `set name as <type> to <value>` **declares** a new variable with an explicit type.
  - `set name to <value>` **assigns** if the name exists, otherwise it **creates** a new variable with an inferred type.
- **Shadowing**:
  - Shadowing is only possible via `set name as <type> to <value>`.
  - If a name exists in any enclosing scope, `set name as <type> to <value>` is a **compile-time error**.

## 2. Lifetimes and Values

- No explicit references or pointers yet; all values are passed by value.
- Lifetimes are lexical: a variable exists until the end of its scope.
- Functions capture nothing (no closures yet).

## 3. Function Semantics

- **Explicit return only**:
  - Non-`void` functions must use `return <expr>`.
  - `void` functions may use `return` without value or omit `return`.
- Any code path in a non-`void` function must end in `return`, or the compiler errors.
- **Function syntax (current)**:
  - Both `set` and `fun` can introduce a function definition.
  - Parameter types are optional; omitted parameter types default to `i32`.
  - `returns <type>` is optional.
  - If omitted, the return type is inferred from `return` statements.
  - If there are no `return <expr>` statements, the function is `void`.
  - Mixing `return` with and without a value is a compile-time error.

## 4. Boolean Semantics

- **Strict boolean**:
  - Only `bool` is allowed in `if`, `while`, `and`, `or`, `not`.
  - No truthiness for numbers or strings.

## 5. Block Structure (Indentation)

- The lexer emits explicit `INDENT` / `DEDENT` tokens.
- New blocks begin after `then`, `loop while`, `loop for`, `try`, `catch`, and function declarations.
- The parser uses `INDENT`/`DEDENT` to construct blocks. No heuristic indentation checks.

## 6. Type System Semantics (Core Rules)

- **Type checking is mandatory** for:
  - Assignments, function calls, returns, conditionals, binary ops.
- **Type stability**:
  - Once a variable has a type, it cannot change. Any type change is a compile-time error.
  - `set name to <value>` must match the existing variable type.
- **Default types**:
  - Integer literals default to `i32`.
  - Floating-point literals default to `f64`.
  - String literals (`""`) default to `str`.
  - Array literals default to `array[T]` based on element type inference.
- **Numeric rules** (proposed):
  - No implicit widening or narrowing by default.
  - Allow explicit casts via `as <type>`.
  - Binary ops require same type; mixed numeric ops are compile errors without cast.
  - Overflow behavior is defined by target C type (to be tightened later).
- **String rules**:
  - `str` is immutable.
  - `+` on strings is concatenation only if both sides are `str`.
  - Interpolation syntax (future): `"hello {name}"` expands to `str`.

## 7. Error Model (T!E + try/catch)

- `T!E` is an error union: either a `T` or error value of type `E`.
- Assigning/returning a `T` to `T!E` wraps as ok; assigning/returning an `E` wraps as err.
- `T` and `E` must differ; nested error unions are not supported yet.
- `try <expr>` propagates errors to the caller.
  - `try` must be used directly in assignment, `return`, or as a standalone statement.
- `catch`:
  - `try <expr> catch <err>` handles errors in a local scope.
  - If no error occurs, `catch` body is skipped.
- Codegen: use a minimal runtime representation (struct `{ bool ok; T value; E err; }`).

## 8. Modules and Imports

- `import foo` resolves to `foo.1im` relative to:
  1. The current file directory
  2. A configured module search path (future)
- `import foo as bar` (future) for aliasing.
- Only top-level imports (no imports inside blocks).
- Imports are single-evaluated; same module imported multiple times is cached.

## 9. Minimal Core Types (Runtime Library)

These are standard types provided by a small runtime library, **even if C lacks them**.
They are part of the language core for ergonomics and portability.

- **`str`**: immutable UTF-8 string (slice + length). No mutation.
- **Fixed-size arrays**: `[N]T` with indexing and element assignment.
- **Slices**: `[]T` with indexing and `len()`.

### Array and Slice Semantics (current)

- Array literal example: `set nums as [3]i32 to [1, 2, 3]`
- Nested arrays: `set grid as [2][3]i32 to [[1,2,3],[4,5,6]]`
- Element assignment: `set nums[1] to 9`
- Slice creation from literal: `set s as []i32 to [4, 5, 6]`
- `len(x)` works on arrays and slices.
- Array reassignment is not supported yet (only element assignment).
- Slices are backed by a hidden fixed-size array in codegen.

### Current Limitations (arrays/slices)

- No bounds checks (C index semantics).
### Current Limitations (errors)

- `try` cannot appear inside larger expressions yet (e.g. `1 + try f()`).

### Built-in functions (current)

- `print(x)` prints a single value.
- `len(x)` returns the length of an array or slice.

The runtime library will be C-compatible and injected by codegen.

## 10. Open Decisions

- Numeric promotion: allow implicit widening in arithmetic?
- Overflow: wrap vs trap?
- String interpolation syntax and escaping rules.
- Array semantics: copy-on-write vs reference-counted vs value-copy?
