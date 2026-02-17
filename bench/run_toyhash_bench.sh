#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPILER="$ROOT_DIR/compiler/zig-out/bin/1im"
OUT_DIR="$ROOT_DIR/bench/out"
ZIG_CACHE_DIR="$OUT_DIR/zig-cache"

SRC_1IM="$ROOT_DIR/bench/toyhash_parallel.1im"

mkdir -p "$OUT_DIR" "$ZIG_CACHE_DIR"

if [ ! -f "$COMPILER" ]; then
    echo "Compiler not found at $COMPILER"
    echo "Building compiler..."
    (cd "$ROOT_DIR/compiler" && zig build)
fi

echo "--- Building 1im toyhash parallel benchmark ---"
"$COMPILER" "$SRC_1IM" >/dev/null 2>"$OUT_DIR/bench_compile.log"

CODEGEN_DIR="$ROOT_DIR/bench/codegen"
C_SRC="$CODEGEN_DIR/toyhash_parallel.c"
ONEIM_BIN="$CODEGEN_DIR/toyhash_parallel"
if [ ! -f "$ONEIM_BIN" ]; then
    echo "1im binary not found at $ONEIM_BIN"
    exit 1
fi

ONEIM_PAR_BIN="$CODEGEN_DIR/toyhash_parallel_threads"
cc -O3 -march=native -pthread -o "$ONEIM_PAR_BIN" "$C_SRC" >/dev/null 2>&1

if [ ! -f "$ONEIM_PAR_BIN" ]; then
    echo "1im parallel bench binary not found at $ONEIM_PAR_BIN"
    exit 1
fi

echo "--- Building Zig toyhash sequential benchmark ---"
zig build-exe "$ROOT_DIR/bench/toyhash.zig" -OReleaseFast -femit-bin="$OUT_DIR/toyhash_zig" \
  --cache-dir "$ZIG_CACHE_DIR" --global-cache-dir "$ZIG_CACHE_DIR" >/dev/null

ZIG_BIN="$OUT_DIR/toyhash_zig"

echo "--- Running 1im parallel binary ---"
TIME_1IM="$OUT_DIR/time_1im_toyhash.txt"
/usr/bin/time -p -o "$TIME_1IM" "$ONEIM_PAR_BIN" >/dev/null 2>&1
cat "$TIME_1IM"

echo "--- Running Zig sequential binary ---"
TIME_ZIG="$OUT_DIR/time_zig_toyhash.txt"
/usr/bin/time -p -o "$TIME_ZIG" "$ZIG_BIN" >/dev/null 2>&1
cat "$TIME_ZIG"
