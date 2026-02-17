#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/bench/out"

mkdir -p "$OUT_DIR"

echo "=============================="
echo "Prime Benchmark (sequential)"
echo "=============================="
"$ROOT_DIR/bench/run_prime_bench.sh"

echo ""
echo "=============================="
echo "Fib Benchmark (sequential)"
echo "=============================="
"$ROOT_DIR/bench/run_fib_bench.sh"
