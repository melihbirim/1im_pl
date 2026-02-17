#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPILER="$ROOT_DIR/compiler/zig-out/bin/1im"
OUT_DIR="$ROOT_DIR/bench/out"
ZIG_CACHE_DIR="$OUT_DIR/zig-cache"

N=10000
REPEAT=5000
SRC_1IM="$OUT_DIR/btree_${N}.1im"

mkdir -p "$OUT_DIR"
mkdir -p "$ZIG_CACHE_DIR"

if [ ! -f "$COMPILER" ]; then
    echo "Compiler not found at $COMPILER"
    echo "Building compiler..."
    (cd "$ROOT_DIR/compiler" && zig build)
fi

zeros=$(awk -v n="$N" 'BEGIN{for(i=0;i<n;i++){printf "0"; if(i<n-1) printf ","}}')

cat > "$SRC_1IM" <<EOF2
# Binary tree benchmark (${N} nodes, repeat ${REPEAT})

set values as [${N}]i32 to [${zeros}]
set left as [${N}]i32 to [${zeros}]
set right as [${N}]i32 to [${zeros}]
set stack as [${N}]i32 to [${zeros}]

loop for i in 0..${N}
    set values[i] to i
    set li to i * 2 + 1
    if li < ${N} then
        set left[i] to li
    else
        set left[i] to -1
    set ri to i * 2 + 2
    if ri < ${N} then
        set right[i] to ri
    else
        set right[i] to -1

set top as i32 to 0
set stack[top] to 0
set top to top + 1
set sum as i32 to 0

loop for rep in 0..${REPEAT}
    set top to 0
    set stack[top] to 0
    set top to top + 1
    set sum to 0
    loop while top > 0
        set top to top - 1
        set node to stack[top]
        set sum to sum + values[node]
        set l to left[node]
        if l != -1 then
            set stack[top] to l
            set top to top + 1
        set r to right[node]
        if r != -1 then
            set stack[top] to r
            set top to top + 1

set sum to sum
EOF2

echo "--- Building 1im benchmark ---"
"$COMPILER" "$SRC_1IM" >/dev/null 2>"$OUT_DIR/bench_compile.log"

ONEIM_BIN="$OUT_DIR/codegen/btree_${N}"
if [ ! -f "$ONEIM_BIN" ]; then
    echo "1im binary not found at $ONEIM_BIN"
    exit 1
fi

echo "--- Building Zig benchmark ---"
zig build-exe "$ROOT_DIR/bench/btree.zig" -OReleaseFast -femit-bin="$OUT_DIR/btree_zig_${N}" \
  --cache-dir "$ZIG_CACHE_DIR" --global-cache-dir "$ZIG_CACHE_DIR" >/dev/null

ZIG_BIN="$OUT_DIR/btree_zig_${N}"

echo "--- Running 1im binary ---"
TIME_1IM="$OUT_DIR/time_1im.txt"
/usr/bin/time -p -o "$TIME_1IM" "$ONEIM_BIN" >/dev/null 2>&1
cat "$TIME_1IM"

echo "--- Running Zig binary ---"
TIME_ZIG="$OUT_DIR/time_zig.txt"
/usr/bin/time -p -o "$TIME_ZIG" "$ZIG_BIN" >/dev/null 2>&1
cat "$TIME_ZIG"
