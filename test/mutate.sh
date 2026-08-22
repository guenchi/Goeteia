#!/bin/sh
# Mutation runs, in a worktree that is about to be deleted.
#
# WHY THIS EXISTS -- three incidents in one batch, all from mutating the
# live tree and all recoverable only by luck:
#
#   1. a mutation was left behind when the run timed out; the restore
#      command was in the same shell command as the run, so the kill
#      took the restore with it.  `shasum -c` caught it.
#   2. the same shape again, and that time the leftover mutation was
#      committed and pushed (fd3378c) -- the writer's limit sat at
#      99999999 in the public repository, so the guard it was testing
#      had never been in force.
#   3. a mutation looked green and was not: the text changed and the
#      file compiled, but the input under test behaved exactly as
#      before, so "nothing noticed" was a statement about nothing.
#
# 1 and 2 are why the mutation happens in a disposable worktree: a
# killed run leaves a directory that is about to be removed, and the
# live tree cannot carry a mutation into a commit.  3 is why --probe
# exists: it makes "the behaviour actually changed" a step the tool
# performs rather than one the operator remembers.
#
# EVERY VERDICT LINE CARRIES ITS DENOMINATOR.  A verdict is the line
# that gets quoted; a warning at the top is the line that gets scrolled
# past.  "the whole suite is green under this mutation" would be a
# sentence about 427 tests while sounding like one about 438 -- so the
# count travels with the word, or the word is not said.
#
# Usage:
#   test/mutate.sh FILE OLD NEW gate            [--probe P.ss]
#   test/mutate.sh FILE OLD NEW SUITE           [--probe P.ss]
#
#   FILE   path, relative to the repo, to mutate
#   OLD    exact text to replace; must occur exactly once
#   NEW    text to put in its place
#   gate   run the whole of run-tests.sh, clean first, then mutated,
#          so the two counts come from one tree and one environment
#   SUITE  a name under test/ (with or without .ss) -- ONE suite, and
#          the verdict says so, because one suite is not the gate
#   P.ss   a program whose output must DIFFER between the clean and the
#          mutated tree.  Without it the tool cannot tell a mutation
#          that changed behaviour from one that only changed bytes.
#
# GOETEIA_RASTERLIB: run-tests.sh finds the Python reference by walking
# up to ../10/, which a worktree under /tmp cannot do.  Set this to the
# path of rasterlib.py to keep the gate's full width; when it is not
# set the gate announces a named SKIP and runs 11 fewer tests, and
# every verdict line below says `rasterlib absent` so that the number
# and the word are never separated.
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
FILE="$1"; OLD="$2"; NEW="$3"; TARGET="$4"
PROBE=""
[ "$5" = "--probe" ] && PROBE="$6"
[ -n "$TARGET" ] || { echo "usage: $0 FILE OLD NEW gate|SUITE [--probe P.ss]" >&2; exit 2; }

RL_NOTE=""
if [ -n "${GOETEIA_RASTERLIB:-}" ] && [ -f "${GOETEIA_RASTERLIB}" ]; then
    export GOETEIA_RASTERLIB
else
    RL_NOTE=" — rasterlib absent, cross-implementation comparison not run"
fi

W=$(mktemp -d "${TMPDIR:-/tmp}/goeteia-mutate.XXXXXX")
trap 'rm -rf "$W"; git -C "$REPO" worktree prune >/dev/null 2>&1 || true' EXIT INT TERM
git -C "$REPO" worktree add --detach "$W/t" HEAD >/dev/null 2>&1
# the live tree's UNCOMMITTED state too: a mutation judged against HEAD
# while the work sits uncommitted is judging a tree nobody has.
(cd "$REPO" && git status --porcelain | awk '{print $NF}') | while read -r f; do
    [ -f "$REPO/$f" ] && { mkdir -p "$W/t/$(dirname "$f")"; cp "$REPO/$f" "$W/t/$f"; }
done

run_probe() { # dir -> stdout of the probe, or the word FAILED
    [ -n "$PROBE" ] || return 0
    cp "$REPO/$PROBE" "$1/__probe.ss" 2>/dev/null || cp "$PROBE" "$1/__probe.ss"
    ( cd "$1" && rm -f __probe.wasm \
      && ./bin/goeteiac __probe.ss __probe.wasm >/dev/null 2>&1 \
      && ${NODE-node} rt/run.mjs __probe.wasm 2>&1 | head -1 ) || echo FAILED
}

cp "$W/t/$FILE" "$W/pre.keep"      # the pre-mutation file, for the clean baseline
before=$(run_probe "$W/t")

python3 - "$W/t/$FILE" "$OLD" "$NEW" <<'PY' || { echo "⛔ NOT LANDED — the text to replace does not occur exactly once (no reading)$RL_NOTE"; exit 0; }
import io, sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding='utf-8').read()
n = s.count(old)
if n != 1:
    sys.stderr.write("occurrences: %d\n" % n); sys.exit(1)
io.open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY

after=$(run_probe "$W/t")
if [ -n "$PROBE" ]; then
    if [ "$before" = "FAILED" ] || [ "$after" = "FAILED" ]; then
        echo "⛔ PROBE FAILED to build or run — no reading$RL_NOTE"; exit 0
    fi
    if [ "$before" = "$after" ]; then
        echo "⛔ INERT — the file changed but the probe still answers '$after'; this mutation tests nothing$RL_NOTE"
        exit 0
    fi
fi

if [ "$TARGET" = gate ]; then
    # Clean first, in THIS worktree and THIS environment, so that the
    # two counts are comparable -- a denominator measured on some other
    # tree is not a denominator.  The clean baseline is the tree WITHOUT
    # the mutation, not HEAD: `git stash` would also take away the
    # uncommitted work carried in above, and M and N would then come
    # from two different trees while being printed as a ratio.
    cp "$W/t/$FILE" "$W/mutated.keep"
    cp "$W/pre.keep" "$W/t/$FILE"
    ( cd "$W/t" && ./run-tests.sh > "$W/clean.log" 2>&1 ) || true
    M=$(grep -cE '^ok ' "$W/clean.log" || true)
    cp "$W/mutated.keep" "$W/t/$FILE"
    ( cd "$W/t" && ./run-tests.sh > "$W/mut.log" 2>&1 ) && ec=0 || ec=$?
    N=$(grep -cE '^ok ' "$W/mut.log" || true)
    named=$(grep -E '^FAIL|^TIMEOUT' "$W/mut.log" | grep -v nodraw | head -1)
    if [ "$ec" -eq 0 ]; then
        echo "🟢 GREEN — the whole gate notices nothing (ok=$N/$M)$RL_NOTE"
    else
        echo "✅ RED (ok=$N/$M) <- ${named:-unnamed failure}$RL_NOTE"
    fi
else
    s=${TARGET%.ss}
    ( cd "$W/t" && rm -f __m.wasm && ./bin/goeteiac "test/$s.ss" __m.wasm >/dev/null 2>&1 ) || true
    [ -f "$W/t/__m.wasm" ] || { echo "⛔ the mutant does not compile — no reading$RL_NOTE"; exit 0; }
    ( cd "$W/t" && timeout 400 ${NODE-node} rt/run.mjs __m.wasm > "$W/one.log" 2>&1 ) || true
    n=$(grep -ciE '✗|FAIL' "$W/one.log" || true)
    if [ "$n" -gt 0 ]; then
        echo "✅ RED (test/$s.ss only — 1 suite, NOT the gate) <- $(grep -iE '✗|FAIL' "$W/one.log" | head -1)$RL_NOTE"
    else
        echo "🟢 GREEN (test/$s.ss only — 1 suite, NOT the gate; the gate may still notice)$RL_NOTE"
    fi
fi
