#!/bin/sh
# Regenerate counter-embedded.html by running the site-generator
# program: the page's interactive part compiles inside its
# (conjure auto ...) mount point at generation time.
#
# Usage: mk-counter-embedded.sh [OUTFILE]
# With no argument it writes examples/counter-embedded.html, which is
# what regenerating the committed page means.  With one, it writes
# there instead and leaves the committed page alone, which is what a
# check comparing a fresh build against the committed one needs: one
# recipe in one place, rather than a second copy of these steps living
# in the checker.
set -e

# Resolved BEFORE the cd below.  A relative OUTFILE on the command
# line means what the caller meant by it; resolving it after the cd
# would silently place it relative to the repository root instead, and
# the caller would be told a file was written where none appeared.
OUT=${1-}
if [ -n "$OUT" ]; then
    case "$OUT" in
        /*) ;;
        *) OUT="$PWD/$OUT" ;;
    esac
fi

cd "$(dirname "$0")/.."
: "${OUT:=examples/counter-embedded.html}"
OUTDIR=$(dirname "$OUT")

# Two things this script used to get wrong.  The tree already knew how
# to do both: build-self.sh and rebuild.sh are the precedent.
#
# The page was written by redirecting onto it.  A redirect truncates
# its target before the command on the left has produced anything, so
# a generator that died halfway would leave the committed page
# destroyed rather than stale -- the artifact lost while trying to
# refresh it.  It did die, every time, between 1.7.0 and 1.7.1, and
# the page survived only because set -e stopped one step earlier: by
# luck of which step failed, not by anything here.  build-self.sh
# writes goeteia.wasm.new.$$ and moves it into place for this reason,
# and compares the published file with the verified one afterwards.
#
# The intermediate module had a fixed name under /tmp, so two trees
# regenerating at once would each compile over the other and publish a
# page built from a module it never compiled.  mktemp gives each run
# its own.
T=$(mktemp -d "${TMPDIR:-/tmp}/goeteia-counter-page.XXXXXX") || exit 1
STAGED="$OUTDIR/.counter-embedded.html.new.$$"
# EXIT alone is not a cleanup guarantee.  Measured on this machine: an
# uncaught TERM runs the EXIT trap under bash but NOT under dash or zsh,
# and /bin/sh is dash on most Linux systems -- so the leak is invisible
# here by construction.  Catching the signals and exiting makes the EXIT
# trap reachable on all three.
trap 'rm -rf "$T"; rm -f "$STAGED"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

./bin/goeteiac examples/counter-page.ss "$T/counter-page.wasm"
node rt/run.mjs "$T/counter-page.wasm" > "$T/counter-embedded.html"

# Nothing replaces the destination until the whole generation has
# succeeded, and this holds for a path given on the command line as
# much as for the committed page: the staged copy lands in the
# destination's own directory so the move that follows is within one
# directory and cannot be interrupted partway.
cp "$T/counter-embedded.html" "$STAGED"
mv "$STAGED" "$OUT"

# What is published is what was generated, asserted rather than
# assumed, as rebuild.sh asserts it for the snapshot.
if ! cmp -s "$OUT" "$T/counter-embedded.html"; then
    echo "published page differs from the page just generated" >&2
    exit 1
fi
echo "$OUT regenerated"
