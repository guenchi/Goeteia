#!/bin/sh
# Build the self-hosted compiler and verify the fixpoint:
#   stage1 = Chez-hosted goeteia compiling (compiler.ss + wasm-driver.ss)
#   stage2 = stage1 compiling the same source
# stage1 and stage2 must be byte-identical.
set -e
cd "$(dirname "$0")"

# Intermediates go to a directory unique to THIS invocation.  The paths
# used to be fixed under /tmp, so two rebuilds at once overwrote each
# other's source and stage2, and the fixpoint `cmp` below would then be
# comparing artifacts from two different runs -- which can read either
# way.  A false green there is the worse half: it would certify a
# compiler that never reproduced itself.  (run-tests.sh had the same
# defect and the same fix.)
T=$(mktemp -d "${TMPDIR:-/tmp}/goeteia-self.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

cat src/compiler.ss src/js-backend.ss src/wasm-driver.ss > "$T/self-src.ss"

echo "stage1: Chez-hosted compiler compiling the compiler..."
./bin/goeteiac "$T/self-src.ss" goeteia.wasm
echo "  goeteia.wasm: $(wc -c < goeteia.wasm) bytes"

echo "stage2: self-hosted compiler compiling the compiler..."
${NODE-node} rt/compile.mjs goeteia.wasm "$T/self-src.ss" "$T/stage2.wasm"
echo "  stage2: $(wc -c < "$T/stage2.wasm") bytes"

if cmp -s goeteia.wasm "$T/stage2.wasm"; then
    echo "fixpoint: stage1 == stage2"
else
    echo "FIXPOINT FAILED: stage1 and stage2 differ"
    exit 1
fi
