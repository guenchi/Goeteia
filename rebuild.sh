#!/bin/sh
# Rebuild the compiler snapshot using only the checked-in snapshot and
# Node -- no host Scheme required:
#   candidate = current snapshot compiling the (possibly edited) source
#   verify    = candidate compiling the source again
# The two must agree byte-for-byte before the snapshot is replaced.
# (./build-self.sh does the stronger cross-host check against Chez.)
set -e
cd "$(dirname "$0")"

# Intermediates go to a directory unique to THIS invocation.  The paths
# used to be fixed under /tmp, so two rebuilds running at once wrote to
# the same candidate and verify files: the `cmp` below could then be
# comparing one run's candidate against another run's verify, and the
# file finally published need not be either of them.  A false green
# there is the worse half -- it would install a compiler that was never
# shown to reproduce itself.  The trap is armed at creation, before
# anything is written, so an interrupt cannot leave the directory
# behind.
T=$(mktemp -d "${TMPDIR:-/tmp}/goeteia-rebuild.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

cat src/compiler.ss src/js-backend.ss src/wasm-driver.ss > "$T/self-src.ss"

echo "candidate: current snapshot compiling the source..."
${NODE-node} rt/compile.mjs goeteia.wasm "$T/self-src.ss" "$T/candidate.wasm"

echo "verify: candidate compiling the source..."
${NODE-node} rt/compile.mjs "$T/candidate.wasm" "$T/self-src.ss" "$T/verify.wasm"

if cmp -s "$T/candidate.wasm" "$T/verify.wasm"; then
    echo "fixpoint: candidate == verify"
else
    echo "FIXPOINT FAILED: candidate and verify differ; snapshot unchanged"
    exit 1
fi

# Publish the candidate that was just compared, staging it beside the
# snapshot so the rename happens within one filesystem and is atomic.
cp "$T/candidate.wasm" "./goeteia.wasm.new.$$"
mv "./goeteia.wasm.new.$$" goeteia.wasm

# The published file must be the compared one.  Binding verification to
# publication by construction is the intent; this checks it happened,
# because "verified A, shipped B" costs one wrong filename and leaves no
# other trace.
if cmp -s goeteia.wasm "$T/candidate.wasm"; then
    echo "published: goeteia.wasm is the verified candidate ($(wc -c < goeteia.wasm) bytes)"
else
    echo "PUBLISH FAILED: goeteia.wasm is not the artifact that was verified"
    exit 1
fi
