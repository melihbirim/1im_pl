#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPILER="$ROOT_DIR/compiler/zig-out/bin/1im"
OUT_DIR="$ROOT_DIR/bench/out"
ZIG_CACHE_DIR="$OUT_DIR/zig-cache"

SRC_1IM_PAR="$ROOT_DIR/bench/parallel_block.1im"
SRC_1IM_SEQ="$ROOT_DIR/bench/parallel_block_seq.1im"

mkdir -p "$OUT_DIR" "$ZIG_CACHE_DIR"

if [ ! -f "$COMPILER" ]; then
    echo "Compiler not found at $COMPILER"
    echo "Building compiler..."
    (cd "$ROOT_DIR/compiler" && zig build)
fi

echo "--- Building 1im parallel benchmark ---"
"$COMPILER" "$SRC_1IM_PAR" >/dev/null 2>"$OUT_DIR/bench_compile.log"

echo "--- Building 1im sequential benchmark ---"
"$COMPILER" "$SRC_1IM_SEQ" >/dev/null 2>>"$OUT_DIR/bench_compile.log"

CODEGEN_DIR="$ROOT_DIR/bench/codegen"
C_SRC_PAR="$CODEGEN_DIR/parallel_block.c"
C_SRC_SEQ="$CODEGEN_DIR/parallel_block_seq.c"
ONEIM_BIN="$CODEGEN_DIR/parallel_block"
if [ ! -f "$ONEIM_BIN" ]; then
    echo "1im binary not found at $ONEIM_BIN"
    exit 1
fi

ONEIM_PAR_BIN="$CODEGEN_DIR/parallel_block_threads"
C_VOL_PAR="$CODEGEN_DIR/parallel_block_bench.c"
sed -e 's/int32_t sum /volatile int32_t sum /g' -e 's/int64_t sum /volatile int64_t sum /g' "$C_SRC_PAR" > "$C_VOL_PAR"
cc -O3 -march=native -pthread -o "$ONEIM_PAR_BIN" "$C_VOL_PAR" >/dev/null 2>&1

ONEIM_PAR_OPT_BIN="$CODEGEN_DIR/parallel_block_threads_opt"
C_VOL_PAR_OPT="$CODEGEN_DIR/parallel_block_bench_opt.c"
sed '/printf/d' "$C_VOL_PAR" | awk '/return 0;/ { print "    printf(\"done\\n\");"; } { print }' > "$C_VOL_PAR_OPT"
cc -O3 -march=native -flto -pthread -o "$ONEIM_PAR_OPT_BIN" "$C_VOL_PAR_OPT" >/dev/null 2>&1

ONEIM_SEQ_BIN="$CODEGEN_DIR/parallel_block_seq_opt"
C_VOL_SEQ="$CODEGEN_DIR/parallel_block_seq_bench.c"
sed -e 's/int32_t sum /volatile int32_t sum /g' -e 's/int64_t sum /volatile int64_t sum /g' "$C_SRC_SEQ" > "$C_VOL_SEQ"
cc -O3 -march=native -o "$ONEIM_SEQ_BIN" "$C_VOL_SEQ" >/dev/null 2>&1

echo "--- Building Zig sequential benchmark (Debug) ---"
zig build-exe "$ROOT_DIR/bench/parallel_block.zig" -ODebug -femit-bin="$OUT_DIR/parallel_block_zig_o0" \
  --cache-dir "$ZIG_CACHE_DIR" --global-cache-dir "$ZIG_CACHE_DIR" >/dev/null

echo "--- Building Zig sequential benchmark (OReleaseSafe) ---"
zig build-exe "$ROOT_DIR/bench/parallel_block.zig" -OReleaseSafe -femit-bin="$OUT_DIR/parallel_block_zig_safe" \
  --cache-dir "$ZIG_CACHE_DIR" --global-cache-dir "$ZIG_CACHE_DIR" >/dev/null

echo "--- Building Zig sequential benchmark (OReleaseFast) ---"
zig build-exe "$ROOT_DIR/bench/parallel_block.zig" -OReleaseFast -femit-bin="$OUT_DIR/parallel_block_zig_fast" \
  --cache-dir "$ZIG_CACHE_DIR" --global-cache-dir "$ZIG_CACHE_DIR" >/dev/null

echo "--- Building Zig parallel benchmark (OReleaseFast) ---"
zig build-exe "$ROOT_DIR/bench/parallel_block_parallel.zig" -OReleaseFast -femit-bin="$OUT_DIR/parallel_block_zig_par" \
  --cache-dir "$ZIG_CACHE_DIR" --global-cache-dir "$ZIG_CACHE_DIR" >/dev/null

ZIG_BIN_O0="$OUT_DIR/parallel_block_zig_o0"
ZIG_BIN_SAFE="$OUT_DIR/parallel_block_zig_safe"
ZIG_BIN_FAST="$OUT_DIR/parallel_block_zig_fast"
ZIG_BIN_PAR="$OUT_DIR/parallel_block_zig_par"

export OMP_NUM_THREADS=${OMP_NUM_THREADS:-4}

echo "--- Running Zig sequential binary (Debug) ---"
TIME_ZIG_O0="$OUT_DIR/time_zig_parallel_o0.txt"
/usr/bin/time -p -o "$TIME_ZIG_O0" "$ZIG_BIN_O0" >/dev/null 2>&1
cat "$TIME_ZIG_O0"

echo "--- Running 1im sequential binary ---"
TIME_1IM_SEQ="$OUT_DIR/time_1im_parallel_seq.txt"
/usr/bin/time -p -o "$TIME_1IM_SEQ" "$ONEIM_SEQ_BIN" >/dev/null 2>&1
cat "$TIME_1IM_SEQ"

echo "--- Running 1im parallel binary (OMP_NUM_THREADS=$OMP_NUM_THREADS) ---"
TIME_1IM_PAR="$OUT_DIR/time_1im_parallel.txt"
/usr/bin/time -p -o "$TIME_1IM_PAR" "$ONEIM_PAR_BIN" >/dev/null 2>&1
cat "$TIME_1IM_PAR"

echo "--- Running 1im parallel optimized binary (OMP_NUM_THREADS=$OMP_NUM_THREADS) ---"
TIME_1IM_PAR_OPT="$OUT_DIR/time_1im_parallel_opt.txt"
/usr/bin/time -p -o "$TIME_1IM_PAR_OPT" "$ONEIM_PAR_OPT_BIN" >/dev/null 2>&1
cat "$TIME_1IM_PAR_OPT"

echo "--- Running Zig sequential binary (OReleaseSafe) ---"
TIME_ZIG_SAFE="$OUT_DIR/time_zig_parallel_safe.txt"
/usr/bin/time -p -o "$TIME_ZIG_SAFE" "$ZIG_BIN_SAFE" >/dev/null 2>&1
cat "$TIME_ZIG_SAFE"

echo "--- Running Zig sequential binary (OReleaseFast) ---"
TIME_ZIG_FAST="$OUT_DIR/time_zig_parallel_fast.txt"
/usr/bin/time -p -o "$TIME_ZIG_FAST" "$ZIG_BIN_FAST" >/dev/null 2>&1
cat "$TIME_ZIG_FAST"

echo "--- Running Zig parallel binary (OReleaseFast) ---"
TIME_ZIG_PAR="$OUT_DIR/time_zig_parallel_par.txt"
/usr/bin/time -p -o "$TIME_ZIG_PAR" "$ZIG_BIN_PAR" >/dev/null 2>&1
cat "$TIME_ZIG_PAR"
