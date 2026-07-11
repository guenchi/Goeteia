#!/bin/sh
# Build the self-hosted compiler and verify the fixpoint:
#   stage1 = Chez-hosted schwasm compiling (compiler.ss + wasm-driver.ss)
#   stage2 = stage1 compiling the same source
# stage1 and stage2 must be byte-identical.
set -e
cd "$(dirname "$0")"

cat src/compiler.ss src/wasm-driver.ss > /tmp/schwasm-self-src.ss

echo "stage1: Chez-hosted compiler compiling the compiler..."
./bin/schwasmc /tmp/schwasm-self-src.ss goeteia.wasm
echo "  goeteia.wasm: $(wc -c < goeteia.wasm) bytes"

echo "stage2: self-hosted compiler compiling the compiler..."
${NODE-node} rt/compile.mjs goeteia.wasm /tmp/schwasm-self-src.ss /tmp/schwasm-stage2.wasm
echo "  stage2: $(wc -c < /tmp/schwasm-stage2.wasm) bytes"

if cmp -s goeteia.wasm /tmp/schwasm-stage2.wasm; then
    echo "fixpoint: stage1 == stage2"
else
    echo "FIXPOINT FAILED: stage1 and stage2 differ"
    exit 1
fi
