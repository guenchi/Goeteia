#!/bin/sh
# Rebuild the compiler snapshot using only the checked-in snapshot and
# Node -- no host Scheme required:
#   candidate = current snapshot compiling the (possibly edited) source
#   verify    = candidate compiling the source again
# The two must agree byte-for-byte before the snapshot is replaced.
# (./build-self.sh does the stronger cross-host check against Chez.)
set -e
cd "$(dirname "$0")"

cat src/compiler.ss src/wasm-driver.ss > /tmp/schwasm-self-src.ss

echo "candidate: current snapshot compiling the source..."
${NODE-node} rt/compile.mjs goeteia.wasm /tmp/schwasm-self-src.ss /tmp/schwasm-candidate.wasm

echo "verify: candidate compiling the source..."
${NODE-node} rt/compile.mjs /tmp/schwasm-candidate.wasm /tmp/schwasm-self-src.ss /tmp/schwasm-verify.wasm

if cmp -s /tmp/schwasm-candidate.wasm /tmp/schwasm-verify.wasm; then
    mv /tmp/schwasm-candidate.wasm goeteia.wasm
    echo "fixpoint: candidate == verify; snapshot updated ($(wc -c < goeteia.wasm) bytes)"
else
    echo "FIXPOINT FAILED: candidate and verify differ; snapshot unchanged"
    exit 1
fi
