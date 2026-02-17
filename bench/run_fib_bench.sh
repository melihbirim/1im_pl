#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPILER="$ROOT_DIR/compiler/zig-out/bin/1im"
OUT_DIR="$ROOT_DIR/bench/out"
ZIG_CACHE_DIR="$OUT_DIR/zig-cache"

N=35
REPEAT=50000000
SRC_1IM="$OUT_DIR/fib_${N}.1im"

mkdir -p "$OUT_DIR" "$ZIG_CACHE_DIR"

if [ ! -f "$COMPILER" ]; then
    echo "Compiler not found at $COMPILER"
    echo "Building compiler..."
    (cd "$ROOT_DIR/compiler" && zig build)
fi

cat > "$SRC_1IM" <<EOF2
# Fibonacci benchmark (N=${N}, repeat ${REPEAT})

set total as i64 to 0
set rep as i64 to 0

loop while rep < ${REPEAT}
    set a as i64 to 0
    set b as i64 to 1
    set i as i64 to 0
    loop while i < ${N}
        set next to a + b
        set a to b
        set b to next
        set i to i + 1
    set total to total + a + rep
    set rep to rep + 1

print(total)
EOF2

echo "--- Building 1im fib benchmark ---"
"$COMPILER" "$SRC_1IM" >/dev/null 2>"$OUT_DIR/bench_compile.log"

C_SRC="$OUT_DIR/codegen/fib_${N}.c"
ONEIM_BIN="$OUT_DIR/codegen/fib_${N}"
if [ ! -f "$ONEIM_BIN" ]; then
    echo "1im binary not found at $ONEIM_BIN"
    exit 1
fi

# Prevent optimizer from removing the loop.
C_VOL="$OUT_DIR/codegen/fib_${N}_bench.c"
ONEIM_BENCH_BIN="$OUT_DIR/codegen/fib_${N}_bench"
sed 's/int64_t total /volatile int64_t total /' "$C_SRC" > "$C_VOL"
cc -O3 -march=native -o "$ONEIM_BENCH_BIN" "$C_VOL" >/dev/null 2>&1

if [ ! -f "$ONEIM_BENCH_BIN" ]; then
    echo "1im bench binary not found at $ONEIM_BENCH_BIN"
    exit 1
fi

echo "--- Building Zig fib benchmark ---"
zig build-exe "$ROOT_DIR/bench/fib.zig" -OReleaseFast -femit-bin="$OUT_DIR/fib_zig_${N}" \
  --cache-dir "$ZIG_CACHE_DIR" --global-cache-dir "$ZIG_CACHE_DIR" >/dev/null

ZIG_BIN="$OUT_DIR/fib_zig_${N}"

echo "--- Running 1im binary ---"
TIME_1IM="$OUT_DIR/time_1im_fib.txt"
/usr/bin/time -p -o "$TIME_1IM" "$ONEIM_BENCH_BIN" >/dev/null 2>&1
cat "$TIME_1IM"

echo "--- Running Zig binary ---"
TIME_ZIG="$OUT_DIR/time_zig_fib.txt"
/usr/bin/time -p -o "$TIME_ZIG" "$ZIG_BIN" >/dev/null 2>&1
cat "$TIME_ZIG"
