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
# A handler that does not exit RETURNS to where the signal arrived, so
# listing INT and TERM beside EXIT removed this workspace and then let
# the script carry on into it.  The signal traps only exit; the EXIT
# trap they reach does the removing.
trap 'rm -rf "$T"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The self-source is compiled AS A PROGRAM, and a program begins with an
# import form -- the three files are library sources and carry no clause
# of their own, so without this the compiler refuses to compile itself
# the moment the empty-map rule is on.
#
# d0aef3e turned that rule on and gave this line to rebuild.sh.  It did
# not give it here, and nothing noticed, because this script is not part
# of any suite: it is run by hand.  For the fifty-six commits since, the
# snapshot was republished eleven times and the cross-host check against
# Chez -- the stronger of the two, which rebuild.sh's own comment points
# at -- ran none of them.  A correction applied to one of two files that
# needed it is the shape this whole batch has been about.
{ echo '(import (rnrs))'; cat src/compiler.ss src/js-backend.ss src/wasm-driver.ss; } > "$T/self-src.ss"

# stage1 is built into the temporary directory, NOT over the checked-in
# snapshot.  Writing it in place first meant that a stage2 failure, or a
# fixpoint mismatch, left an unverified compiler installed as the
# snapshot -- the build announced failure while having already published
# the thing it failed to verify.  Nothing touches goeteia.wasm until
# every check below has passed.
echo "stage1: Chez-hosted compiler compiling the compiler..."
./bin/goeteiac "$T/self-src.ss" "$T/stage1.wasm"
echo "  stage1: $(wc -c < "$T/stage1.wasm") bytes"

echo "stage2: self-hosted compiler compiling the compiler..."
${NODE-node} rt/compile.mjs "$T/stage1.wasm" "$T/self-src.ss" "$T/stage2.wasm"
echo "  stage2: $(wc -c < "$T/stage2.wasm") bytes"

if cmp -s "$T/stage1.wasm" "$T/stage2.wasm"; then
    echo "fixpoint: stage1 == stage2"
else
    echo "FIXPOINT FAILED: stage1 and stage2 differ; snapshot unchanged"
    exit 1
fi

# Publish the verified artifact.  The staging copy is made beside the
# snapshot rather than in $T so that the rename is within one
# filesystem and therefore atomic: a reader either sees the old
# snapshot or the new one, never a half-written file.
cp "$T/stage1.wasm" "./goeteia.wasm.new.$$"
mv "./goeteia.wasm.new.$$" goeteia.wasm

# What was published must be what was verified.  "Verified A, shipped B"
# is the standard way for a script like this to go wrong -- one copy
# naming the wrong file is enough -- and it is invisible unless the two
# are compared after the fact rather than assumed equal by construction.
if cmp -s goeteia.wasm "$T/stage1.wasm"; then
    echo "published: goeteia.wasm is the verified stage1 ($(wc -c < goeteia.wasm) bytes)"
else
    echo "PUBLISH FAILED: goeteia.wasm is not the artifact that was verified"
    exit 1
fi
