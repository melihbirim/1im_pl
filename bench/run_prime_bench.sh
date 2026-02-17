#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPILER="$ROOT_DIR/compiler/zig-out/bin/1im"
OUT_DIR="$ROOT_DIR/bench/out"
ZIG_CACHE_DIR="$OUT_DIR/zig-cache"

N=5000
REPEAT=5000
SRC_1IM="$OUT_DIR/prime_${N}.1im"

mkdir -p "$OUT_DIR" "$ZIG_CACHE_DIR"

if [ ! -f "$COMPILER" ]; then
    echo "Compiler not found at $COMPILER"
    echo "Building compiler..."
    (cd "$ROOT_DIR/compiler" && zig build)
fi

cat > "$SRC_1IM" <<EOF2
# Prime benchmark (N=${N}, repeat ${REPEAT})

set total as i32 to 0

loop for rep in 0..${REPEAT}
    set count as i32 to 0
    set n as i32 to 2
    loop while n <= ${N}
        set is_prime as bool to true
        set i as i32 to 2
        loop while i * i <= n
            if n % i == 0 then
                set is_prime to false
            set i to i + 1
        if is_prime then
            set count to count + 1
        set n to n + 1
    set total to total + count

print(total)
EOF2

echo "--- Building 1im prime benchmark ---"
"$COMPILER" "$SRC_1IM" >/dev/null 2>"$OUT_DIR/bench_compile.log"

C_SRC="$OUT_DIR/codegen/prime_${N}.c"
ONEIM_BIN="$OUT_DIR/codegen/prime_${N}"
if [ ! -f "$ONEIM_BIN" ]; then
    echo "1im binary not found at $ONEIM_BIN"
    exit 1
fi

# Prevent optimizer from removing the loop.
C_VOL="$OUT_DIR/codegen/prime_${N}_bench.c"
ONEIM_BENCH_BIN="$OUT_DIR/codegen/prime_${N}_bench"
sed 's/int32_t total /volatile int32_t total /' "$C_SRC" > "$C_VOL"
cc -O3 -march=native -o "$ONEIM_BENCH_BIN" "$C_VOL" >/dev/null 2>&1

if [ ! -f "$ONEIM_BENCH_BIN" ]; then
    echo "1im bench binary not found at $ONEIM_BENCH_BIN"
    exit 1
fi

echo "--- Building Zig prime benchmark ---"
zig build-exe "$ROOT_DIR/bench/prime.zig" -OReleaseFast -femit-bin="$OUT_DIR/prime_zig_${N}" \
  --cache-dir "$ZIG_CACHE_DIR" --global-cache-dir "$ZIG_CACHE_DIR" >/dev/null

ZIG_BIN="$OUT_DIR/prime_zig_${N}"

echo "--- Running 1im binary ---"
TIME_1IM="$OUT_DIR/time_1im_prime.txt"
/usr/bin/time -p -o "$TIME_1IM" "$ONEIM_BENCH_BIN" >/dev/null 2>&1
cat "$TIME_1IM"

echo "--- Running Zig binary ---"
TIME_ZIG="$OUT_DIR/time_zig_prime.txt"
/usr/bin/time -p -o "$TIME_ZIG" "$ZIG_BIN" >/dev/null 2>&1
cat "$TIME_ZIG"
