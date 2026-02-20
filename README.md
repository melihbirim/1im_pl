# 1im Programming Language — First Compiler

**Status:** Proof of concept working ✅

## What is 1im?

1im is a statically-typed, systems programming language with natural-language syntax designed to compete with C and Zig while also replacing bash as the default scripting language. See [1im_grammar_v1.md](1im_grammar_v1.md) for the full language specification.

## What Works Now (v0.1-alpha)

This is the **first working compiler** for 1im. Currently implemented:

- ✅ Lexer (tokenization)
- ✅ Parser (recursive descent → AST)
- ✅ Code generation (to C)
- ✅ Automatic compilation via system C compiler
- ✅ Basic types and annotations: `i8`-`i64`, `u8`-`u64`, `f32`, `f64`, `bool`, `str`
- ✅ Variables: `set <name> to <value>` and `set <name> as <type> to <value>`
- ✅ Functions with typed params/returns
- ✅ Control flow: `if`/`then`/`else`, `loop while`
- ✅ Built-in functions: `print(<expr>)`
- ✅ Built-in functions: `len(<array_or_slice>)`
- ✅ Fixed-size arrays `[N]T` with literals and indexing
- ✅ Slices `[]T` with indexing
- ✅ Arithmetic expressions: `+`, `-`, `*`, `/`, `%`
- ✅ Comments: `#`
- ⚠️ `loop for` and `try/catch` are parsed but not codegened yet (compiler errors)

## Example

```
# hello.1im — first 1im program
set age to 41
print(age)
```

Compiles to:

```c
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>

int main(void) {
    int64_t age = 41;
    printf("%" PRId64 "\n", (int64_t)age);
    return 0;
}
```

Output:

```
41
```

## Test Examples

Phase 1 test programs in `examples/`:

- **[hello.1im](examples/hello.1im)** - First working program (variables + print)
- **[types.1im](examples/types.1im)** - All type annotations (i8-i64, u8-u64, f32, f64, bool, str)
- **[function.1im](examples/function.1im)** - Function with typed parameters and return
- **[if_else.1im](examples/if_else.1im)** - Conditional statements (if/then/else if/else)
- **[while_loop.1im](examples/while_loop.1im)** - While loop with counter
- **[len_array.1im](examples/len_array.1im)** - `len()` on fixed array
- **[len_slice.1im](examples/len_slice.1im)** - `len()` on slice
- **[array_basic.1im](examples/array_basic.1im)** - Fixed-size array literals and indexing
- **[array_nested.1im](examples/array_nested.1im)** - Nested arrays
- **[array_assign.1im](examples/array_assign.1im)** - Array element assignment

Run any example:

```bash
./compiler/zig-out/bin/1im examples/types.1im
```

## Building the Compiler

### Requirements

- Zig 0.15.2+ ([install](https://ziglang.org/download/))
- A C compiler (`cc` — typically gcc or clang/Apple clang on macOS)

### Build

```bash
cd compiler
zig build
```

This creates `compiler/zig-out/bin/1im` — the 1im compiler executable.

### Run

```bash
./compiler/zig-out/bin/1im examples/hello.1im
```

The compiler:

1. Lexes your `.1im` source
2. Parses it into an AST
3. Generates C code to `/tmp/_1im_output.c`
4. Compiles the C code with `cc`
5. Runs the resulting binary
6. Prints the output

## What's Next

From the v1 grammar spec, here's what needs implementation (in priority order):

### Phase 1 — Core Language (2-3 months)

- [x] Full type system (`i8`-`i64`, `u8`-`u64`, `f32`, `f64`, `bool`, `str`)
- [x] Type annotations: `set x as i32 to 42`
- [x] Functions: `set add with a as i32, b as i32 returns i32`
- [x] Control flow: `if`/`then`/`else`, `loop while`, `loop for`
- [x] Error handling: `T!E` error unions, `try`, `catch` (parser ready, codegen TODO)
- [ ] String interpolation: `"hello {name}"` (not yet implemented)

**Phase 1 Status:** Parser complete, codegen in progress.  
Lexer, parser, and AST support all Phase 1 constructs. C code generation works for types, functions, `if/else`, and `loop while`. `loop for` and `try/catch` are not codegened yet.

### Phase 2 — Systems Features (2-3 months)

- [ ] Pointers: `*T`, `&x`, `p.*`
- [ ] Structs & methods
- [ ] Enums & tagged unions
- [ ] Memory management: `defer`, allocators
- [ ] C FFI: `extern "C"` declarations
- [ ] Comptime: compile-time evaluation

### Phase 3 — Shell Features (2-3 months)

- [ ] `run` command execution
- [ ] Pipe chains: `run "ls" | "grep foo"`
- [ ] Environment variables: `env("PATH")`
- [ ] `glob` pattern matching
- [ ] Built-in file operations
- [ ] Structured parsers: `ps()`, `df()`, `netstat()`

### Phase 4 — Tooling (1-2 months)

- [ ] LSP server
- [ ] Formatter
- [ ] Package manager
- [ ] Build system (`build.1im`)
- [ ] Testing framework

### Phase 5 — Self-Hosting (3-6 months)

- [ ] Rewrite compiler in 1im itself
- [ ] Bootstrap procedure
- [ ] Delete Zig implementation

## Current Limitations

- `loop for` and `try/catch` are parsed but not codegened yet
- String interpolation is not implemented
- No imports/modules
- Memory leaks in compiler (not a problem for a CLI tool, but noted)

## Directory Structure

```bash
1im_pl/
├── compiler/
│   ├── src/
│   │   ├── main.zig         # Entry point
│   │   ├── lexer.zig        # Tokenization
│   │   ├── token.zig        # Token types
│   │   ├── parser.zig       # Parsing
│   │   ├── ast.zig          # AST node types
│   │   └── codegen.zig      # C code generation
│   ├── build.zig            # Zig build script
│   └── zig-out/bin/1im      # Compiled compiler (after build)
├── examples/
│   └── hello.1im            # First working program
└── 1im_grammar_v1.md        # Language specification
```

## Implementation Notes

- **Why Zig?** Fast compile times, no GC (matches 1im's philosophy), excellent LLVM bindings, great cross-compilation support. See discussion in git history.
- **Why compile to C first?** Faster to implement than LLVM IR directly. C backend gives us instant portability and the full C ecosystem. We'll switch to LLVM later for optimization.
- **Memory model:** Currently using Zig's GPA (GeneralPurposeAllocator). Will switch to arena allocator for compiler, which eliminates all cleanup code.

## Contributing

This is a proof-of-concept / learning project. Not accepting PRs yet, but feedback on the language design ([1im_grammar_v1.md](1im_grammar_v1.md)) is welcome.

## License

TBD (will be permissive — MIT or Apache 2.0)

---

**First successful compilation:** February 16, 2026  
**Compiler implementation:** Zig 0.15.2  
**Target:** Native code via C
