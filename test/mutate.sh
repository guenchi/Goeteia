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
#          The check is one-sided, and the direction matters.  A GREEN
#          reading is worthless if the mutation was inert -- nothing
#          could have noticed, because nothing happened -- so the probe
#          protects greens.  A RED reading needs no such protection: a
#          mutation that changed no behaviour cannot make any test
#          answer differently, so red is immune to this class by
#          construction.
#
#          What the probe CANNOT say is "inert".  It says "inert for
#          this input", and there are two quite different reasons for
#          that, which look identical from here:
#
#            the mutation reaches nothing -- a dead branch, or a
#            condition already implied by its neighbours; or
#            the claim is held REDUNDANTLY, and the gate you removed
#            was not the one holding it.
#
#          Measured example of the second: "0xF5..0xFF are never lead
#          bytes" survives removing the `b < 245` bound (the codepoint
#          ceiling rejects those sequences anyway) AND survives raising
#          the codepoint ceiling (the byte bound rejects them anyway).
#          Only relaxing both turns it red.  So an INERT reading is not
#          evidence that a name is empty -- it is a question: is there a
#          second gate?  Answer it by mutating the conjunction, not by
#          concluding.
#
#          Either way the report reads like "no reading", so choosing an
#          input the mutation should reach is the operator's judgement,
#          and a wrong choice suppresses a real reading rather than
#          producing a false one.
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

cp "$W/t/$FILE" "$W/mutated.keep"  # ...and the mutated one, so the
                                   # baseline run can be put back
after=$(run_probe "$W/t")
if [ -n "$PROBE" ]; then
    if [ "$before" = "FAILED" ] || [ "$after" = "FAILED" ]; then
        echo "⛔ PROBE FAILED to build or run — no reading$RL_NOTE"; exit 0
    fi
    if [ "$before" = "$after" ]; then
        echo "⛔ INERT FOR THIS PROBE — the file changed and the probe still answers '$after'. Not evidence the claim is unpinned: the gate you removed may not be the one holding it. Mutate the conjunction before concluding$RL_NOTE"
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
    # ALL of them, for the reason written twelve lines below about the
    # single-suite path -- and this line is the one that matters more.
    # A single-suite reading already carries "1 suite, NOT the gate";
    # THIS one is the verdict that gets quoted when someone asks
    # whether a claim is pinned, and naming the wrong assertion answers
    # a different question convincingly.
    #
    # It stayed broken for a whole round after the reason for fixing it
    # was written down, twelve lines away, on the other path.
    named=$(grep -E '^FAIL|^TIMEOUT' "$W/mut.log" | grep -v nodraw \
            | sed 's/ ([0-9.]*ms)$//' | sort -u | head -4 \
            | tr '\n' '|' | cut -c1-240)
    if [ "$ec" -eq 0 ]; then
        echo "🟢 GREEN — the whole gate notices nothing (ok=$N/$M)$RL_NOTE"
    else
        echo "✅ RED (ok=$N/$M) <- ${named:-unnamed failure}$RL_NOTE"
    fi
else
    s=${TARGET%.ss}; s=${s%.mjs}
    if [ -f "$W/t/test/$s.mjs" ]; then
        # a .mjs suite reports through node:test, so the failing
        # assertion's own message is what comes back
        # The oracle here is node --test's exit status, not a word in
        # its output -- same reason as the .ss branch below.
        if ( cd "$W/t" && timeout 600 ${NODE-node} --test "test/$s.mjs" > "$W/one.log" 2>&1 ); then n=0; else n=1; fi
        s="$s.mjs"
    else
        ( cd "$W/t" && rm -f __m.wasm && ./bin/goeteiac "test/$s.ss" __m.wasm >/dev/null 2>&1 ) || true
        [ -f "$W/t/__m.wasm" ] || { echo "⛔ the mutant does not compile — no reading$RL_NOTE"; exit 0; }
        # stdout ONLY, and stderr kept apart -- run-tests.sh compares
        # `got=$(run_one ...)`, which captures stdout alone.  Folding
        # stderr in made this tool disagree with the gate about any
        # suite that writes a diagnostic there: test/sexpr-limits.ss
        # prints two "NOT EXERCISED HERE" notes and then #t, and every
        # reading of it here was a false RED until this line changed.
        # An instrument that judges a mutation must be the SAME
        # instrument as the gate, not one that resembles it.
        ( cd "$W/t" && timeout 400 ${NODE-node} rt/run.mjs __m.wasm > "$W/one.log" 2> "$W/one.err" ) || true
        # The oracle is the file's own `;; expect:` line, the same one
        # run-tests.sh holds it to.  Scanning the output for the word
        # FAIL is NOT the oracle: plenty of .ss suites answer with a
        # bare #f and say nothing else, and this tool reported those as
        # GREEN -- a verdict weaker than the gate's, which is the one
        # thing a mutation tool must never be.
        want=$(head -1 "$W/t/test/$s.ss" | sed 's/^;; expect: //')
        got=$(cat "$W/one.log")
        # BASELINE FIRST, always.  A suite that does not answer its own
        # `;; expect:` line before the mutation cannot say anything
        # about it afterwards, and reading its red as the mutation's is
        # how this tool spent a batch reporting false REDs for
        # test/sexpr-limits.ss.  This is the no-op control, run every
        # time rather than remembered.
        cp "$W/mutated.keep" "$W/t/$FILE" 2>/dev/null || true
        cp "$W/pre.keep" "$W/t/$FILE"
        ( cd "$W/t" && rm -f __b.wasm && ./bin/goeteiac "test/$s.ss" __b.wasm >/dev/null 2>&1 ) || true
        base=""
        [ -f "$W/t/__b.wasm" ] && base=$( cd "$W/t" && timeout 400 ${NODE-node} rt/run.mjs __b.wasm 2>/dev/null )
        if [ "$base" != "$want" ]; then
            echo "⛔ BASELINE NOT GREEN — test/$s.ss answers '$(echo "$base" | head -c 40)' before any mutation, so nothing here is a reading$RL_NOTE"
            exit 0
        fi
        if [ "$got" = "$want" ]; then n=0; else n=1; fi
        s="$s.ss"
    fi
    if [ "$n" -gt 0 ]; then
        # Anchored, and NOT case-insensitive: `grep -iE FAIL` also
        # matches "failing" and "failure", and it picked a PASSING
        # line ("✔ the transport failing is a rejection") as the
        # explanation of a red.  A pattern loose enough to match prose
        # will eventually match the wrong prose.
        # ALL of them, not the first.  Criterion (1) is "it reddened
        # THAT assertion", and the first failing line is often a
        # neighbour: a mutation frequently trips a golden vector before
        # it trips the claim you derived it from, and reading only the
        # head turns "it did redden the right one" into "it reddened
        # something else".
        detail=$(grep -E '^✖|^✗|^not ok|^FAIL|AssertionError' "$W/one.log" \
                 | grep -v 'failing tests' | sed 's/ ([0-9.]*ms)$//' \
                 | sort -u | head -4 | tr '\n' '|' | cut -c1-200)
        [ -n "$detail" ] || detail="want '$(head -1 "$W/t/test/${s%.mjs}" 2>/dev/null | sed 's/^;; expect: //')', got '$(head -c 60 "$W/one.log")'"
        echo "✅ RED (test/$s only — 1 suite, NOT the gate) <- $detail$RL_NOTE"
    else
        echo "🟢 GREEN (test/$s only — 1 suite, NOT the gate; the gate may still notice)$RL_NOTE"
    fi
fi
