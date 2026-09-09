#!/bin/sh
# Compile and run every test, with the Chez-hosted compiler (stage0)
# and, if goeteia.wasm is present, with the self-hosted compiler
# (stage1).  Each test also compiles and runs on the JS target, whose
# emitted text must agree between hosts byte-for-byte.  Each test's
# first line declares the expected output as ";; expect: <value>".
cd "$(dirname "$0")"
fail=0
# Compiler output goes to a directory unique to THIS invocation.  The
# paths used to be fixed (/tmp/goeteia-test*.wasm), so two runs of this
# script at once overwrote each other's artifacts: the second run's
# `cmp` compared bytes from two different tests and reported cross-host
# failures for most of the tree, with a `got` from whichever test wrote
# last.  Three times across two batches, and every time the red looked
# exactly like a real defect -- so the cost is not the wasted run, it is
# that the evidence from a colliding run is worthless in BOTH
# directions.
T=$(mktemp -d "${TMPDIR:-/tmp}/goeteia-tests.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
# enable JSPI (js-await suspension) when this node accepts the flag
JSPI=""
if ${NODE-node} --experimental-wasm-jspi -e 1 >/dev/null 2>&1; then
    JSPI="--experimental-wasm-jspi"
fi
# A HANG is the one failure this harness could not report.  A test
# that never returns produces no output and no exit status, so the run
# sits there and any notification about it reads as "still going" --
# which is what a slow run looks like too.  Three hangs happened while
# this batch was written (a prelude predicate spinning on a circular
# list, the JSON writer following one, and a mutation run), and none
# of them would have failed a gate: they would have stalled it.
#
# So every compile and every run gets a wall-clock bound, and going
# past it prints a line naming the suite.  Where timeout(1) is absent
# the run still works -- and SAYS so, loudly, because a guard that is
# quietly not there is the shape of defect this was added for.
TLIMIT=${GOETEIA_TEST_TIMEOUT-180}
if command -v timeout >/dev/null 2>&1; then CAP="timeout $TLIMIT"
elif command -v gtimeout >/dev/null 2>&1; then CAP="gtimeout $TLIMIT"
else
    CAP=""
    echo "WARNING: no timeout(1) here -- a hanging test will STALL this run,"
    echo "         not fail it.  Install coreutils to get the bound back."
fi
# 124 is timeout(1)'s own code for "the command outlived the bound".
timed_out() { [ -n "$CAP" ] && [ "$1" -eq 124 ]; }

# A run that TRAPPED did not answer the question wrongly -- it stopped.
# Every cell after the trap silently did not run, so the failures on
# screen are a LOWER BOUND on what is broken, and a reader who counts
# them gets a smaller number than the truth.  This matters here because
# a wasm type trap (`illegal cast`) is not a Scheme condition: `guard`
# cannot catch it, a test file cannot report it, and the only outward
# sign is a non-zero exit beside a partial transcript.  Measured once,
# on a mutant that broke the audio graph: one FAIL line was printed and
# four more cells never ran.
crashed() { [ "$1" -ne 0 ] && ! timed_out "$1"; }
say_if_crashed() {
    crashed "$1" && echo "     ^ the run ENDED EARLY (exit $1): cells after that point did not run," \
                 && echo "       so the failures above are a lower bound, not the whole list"
}

# A test that could not measure what it wanted says so on a line of its
# own.  That line is a note to the reader, not part of the value under
# test: leaving it in the captured output makes the ANNOUNCEMENT fail the
# test (which is what happened -- a discard path went red the first time
# it ran, on stdout being the verdict), and dropping it makes the discard
# invisible, which is the shape the announcement exists to prevent.  So
# it is lifted out of the comparison and printed.
NOTE_RE='^[[:space:]]*NOT (MEASURED|EXERCISED) HERE'
lift_notes() { # raw-output -> prints notes, sets $got to the rest
    printf '%s\n' "$1" | grep -E "$NOTE_RE" || true
    got=$(printf '%s\n' "$1" | grep -vE "$NOTE_RE" || true)
}

run_one() { # wasmfile testfile
    input="${2%.ss}.input"
    if [ -f "$input" ]; then
        $CAP ${NODE-node} $JSPI rt/run.mjs "$1" "$input"
    else
        $CAP ${NODE-node} $JSPI rt/run.mjs "$1"
    fi
}
run_js() { # jsfile testfile
    input="${2%.ss}.input"
    if [ -f "$input" ]; then
        $CAP ${NODE-node} rt/runjs.mjs "$1" "$input"
    else
        $CAP ${NODE-node} rt/runjs.mjs "$1"
    fi
}
# GOETEIA_TESTS narrows the loop to named files, so a change to the
# verdict machinery can be exercised on one test instead of all of
# them.  Unset -- which is how the gate runs it -- it is every test.
for t in ${GOETEIA_TESTS-test/*.ss}; do
    want=$(head -1 "$t" | sed 's/^;; expect: //')
    $CAP ./bin/goeteiac "$t" "$T/test.wasm"; ec=$?
    if timed_out $ec; then
        echo "TIMEOUT $t (stage0 compile) after ${TLIMIT}s"; fail=1; continue
    elif [ $ec -ne 0 ]; then
        echo "FAIL $t (stage0 compile error)"; fail=1; continue
    fi
    raw=$(run_one "$T/test.wasm" "$t"); ec=$?; lift_notes "$raw"
    if timed_out $ec; then
        echo "TIMEOUT $t (stage0 run) after ${TLIMIT}s"; fail=1; continue
    fi
    if [ "$got" = "$want" ]; then
        echo "ok   $t"
    else
        echo "FAIL $t (stage0: want '$want', got '$got')"
        say_if_crashed $ec
        fail=1
    fi
    if [ -f goeteia.wasm ]; then
        if ! ${NODE-node} rt/compile.mjs goeteia.wasm "$t" "$T/test1.wasm" 2>/dev/null; then
            echo "FAIL $t (stage1 compile error)"; fail=1; continue
        fi
        raw=$(run_one "$T/test1.wasm" "$t"); ec=$?; lift_notes "$raw"
        if timed_out $ec; then
            echo "TIMEOUT $t (stage1 run) after ${TLIMIT}s"; fail=1; continue
        fi
        if [ "$got" = "$want" ]; then
            echo "ok   $t (stage1)"
        else
            echo "FAIL $t (stage1: want '$want', got '$got')"
            say_if_crashed $ec
            fail=1
        fi
        # both hosts must emit identical bytes from identical source
        if ! cmp -s "$T/test.wasm" "$T/test1.wasm"; then
            echo "FAIL $t (cross-host: stage0/stage1 bytes differ)"; fail=1
        fi
    fi
    # the JS target answers to the same oracle
    if ! ./bin/goeteiac --js "$t" "$T/test.js"; then
        echo "FAIL $t (js compile error)"; fail=1; continue
    fi
    raw=$(run_js "$T/test.js" "$t"); ec=$?; lift_notes "$raw"
    if timed_out $ec; then
        echo "TIMEOUT $t (js run) after ${TLIMIT}s"; fail=1; continue
    fi
    if [ "$got" = "$want" ]; then
        echo "ok   $t (js)"
    else
        echo "FAIL $t (js: want '$want', got '$got')"
        say_if_crashed $ec
        fail=1
    fi
    if [ -f goeteia.wasm ]; then
        if ! ${NODE-node} rt/compile.mjs --js goeteia.wasm "$t" "$T/test1.js" 2>/dev/null; then
            echo "FAIL $t (stage1 js compile error)"; fail=1; continue
        fi
        if ! cmp -s "$T/test.js" "$T/test1.js"; then
            echo "FAIL $t (cross-host: stage0/stage1 JS text differs)"; fail=1
        fi
    fi
done
if ${NODE-node} test/js-backend-division.mjs; then
    echo "ok   test/js-backend-division.mjs"
else
    echo "FAIL test/js-backend-division.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-bounds.mjs; then
    echo "ok   test/js-backend-bounds.mjs"
else
    echo "FAIL test/js-backend-bounds.mjs"; fail=1
fi
if ${NODE-node} test/run-errors.mjs; then
    echo "ok   test/run-errors.mjs"
else
    echo "FAIL test/run-errors.mjs"; fail=1
fi
if ${NODE-node} test/gltf-p1.mjs; then
    echo "ok   test/gltf-p1.mjs"
else
    echo "FAIL test/gltf-p1.mjs"; fail=1
fi
if ${NODE-node} test/glb-p1.mjs; then
    echo "ok   test/glb-p1.mjs"
else
    echo "FAIL test/glb-p1.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-arity.mjs; then
    echo "ok   test/js-backend-arity.mjs"
else
    echo "FAIL test/js-backend-arity.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-exports.mjs; then
    echo "ok   test/js-backend-exports.mjs"
else
    echo "FAIL test/js-backend-exports.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-memory-bounds.mjs; then
    echo "ok   test/js-backend-memory-bounds.mjs"
else
    echo "FAIL test/js-backend-memory-bounds.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-fl-conversion.mjs; then
    echo "ok   test/js-backend-fl-conversion.mjs"
else
    echo "FAIL test/js-backend-fl-conversion.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-flonum-types.mjs; then
    echo "ok   test/js-backend-flonum-types.mjs"
else
    echo "FAIL test/js-backend-flonum-types.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-pair-types.mjs; then
    echo "ok   test/js-backend-pair-types.mjs"
else
    echo "FAIL test/js-backend-pair-types.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-i31-types.mjs; then
    echo "ok   test/js-backend-i31-types.mjs"
else
    echo "FAIL test/js-backend-i31-types.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-collection-types.mjs; then
    echo "ok   test/js-backend-collection-types.mjs"
else
    echo "FAIL test/js-backend-collection-types.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-tco.mjs; then
    echo "ok   test/js-backend-tco.mjs"
else
    echo "FAIL test/js-backend-tco.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-jspi.mjs; then
    echo "ok   test/js-backend-jspi.mjs"
else
    echo "FAIL test/js-backend-jspi.mjs"; fail=1
fi
if ${NODE-node} test/jsbridge-instance.mjs >/dev/null 2>&1; then
    echo "ok   test/jsbridge-instance.mjs"
else
    echo "FAIL test/jsbridge-instance.mjs"; fail=1
fi
if ${NODE-node} test/fx-loop-generation.mjs >/dev/null 2>&1; then
    echo "ok   test/fx-loop-generation.mjs"
else
    echo "FAIL test/fx-loop-generation.mjs"; fail=1
fi
if ${NODE-node} test/fx-loop-coexistence.mjs >/dev/null 2>&1; then
    echo "ok   test/fx-loop-coexistence.mjs"
else
    echo "FAIL test/fx-loop-coexistence.mjs"; fail=1
fi
if ${NODE-node} test/web-compile-diagnostics.mjs >/dev/null 2>&1; then
    echo "ok   test/web-compile-diagnostics.mjs"
else
    echo "FAIL test/web-compile-diagnostics.mjs"; fail=1
fi
if ${NODE-node} test/reader-diagnostics.mjs >/dev/null 2>&1; then
    echo "ok   test/reader-diagnostics.mjs"
else
    echo "FAIL test/reader-diagnostics.mjs"; fail=1
fi
if ${NODE-node} test/web-external-fallback-fresh.mjs >/dev/null 2>&1; then
    echo "ok   test/web-external-fallback-fresh.mjs"
else
    echo "FAIL test/web-external-fallback-fresh.mjs"; fail=1
fi
if ${NODE-node} test/glyphs-listener-cleanup.mjs >/dev/null 2>&1; then
    echo "ok   test/glyphs-listener-cleanup.mjs"
else
    echo "FAIL test/glyphs-listener-cleanup.mjs"; fail=1
fi
if ${NODE-node} test/glyphs-loop-generation.mjs >/dev/null 2>&1; then
    echo "ok   test/glyphs-loop-generation.mjs"
else
    echo "FAIL test/glyphs-loop-generation.mjs"; fail=1
fi
if ${NODE-node} test/glyphs-scope-dispose.mjs >/dev/null 2>&1; then
    echo "ok   test/glyphs-scope-dispose.mjs"
else
    echo "FAIL test/glyphs-scope-dispose.mjs"; fail=1
fi
if ${NODE-node} test/dev-nocache.mjs; then
    echo "ok   test/dev-nocache.mjs"
else
    echo "FAIL test/dev-nocache.mjs"; fail=1
fi
if ${NODE-node} test/web-fs-nofs.mjs; then
    echo "ok   test/web-fs-nofs.mjs"
else
    echo "FAIL test/web-fs-nofs.mjs"; fail=1
fi
if ${NODE-node} test/args.mjs; then
    echo "ok   test/args.mjs"
else
    echo "FAIL test/args.mjs"; fail=1
fi
if ${NODE-node} test/determinism.mjs; then
    echo "ok   test/determinism.mjs"
else
    echo "FAIL test/determinism.mjs"; fail=1
fi
if ${NODE-node} test/raster-diff.mjs; then
    echo "ok   test/raster-diff.mjs"
else
    echo "FAIL test/raster-diff.mjs"; fail=1
fi
if ${NODE-node} test/verify.mjs; then
    echo "ok   test/verify.mjs"
else
    echo "FAIL test/verify.mjs"; fail=1
fi
if ${NODE-node} test/pack.mjs; then
    echo "ok   test/pack.mjs"
else
    echo "FAIL test/pack.mjs"; fail=1
fi
if ${NODE-node} test/llm-substrate.mjs; then
    echo "ok   test/llm-substrate.mjs"
else
    echo "FAIL test/llm-substrate.mjs"; fail=1
fi
if ${NODE-node} --test test/sexpr-mjs.mjs >/dev/null 2>&1; then
    echo "ok   test/sexpr-mjs.mjs"
else
    echo "FAIL test/sexpr-mjs.mjs"; fail=1
fi
# Its output is kept in a file rather than discarded: a cell that stands
# down (the website manual checks, when the website checkout is not
# beside this tree) announces itself with NOT EXERCISED HERE, and that
# line has to reach the log or the skip is silent -- and a red run's
# output is the part worth reading.
DOCS_OUT="$T/docs-mjs.out"
# The only check here that leaves the machine.  It stands down loudly
# when no browser is present rather than failing, because a suite that
# cannot run without Chrome is a suite people stop running; but on a
# machine that has one, this is the only thing between an invalid
# shader and a release -- the GL that test/pages/* runs against accepts
# every shader it is shown.
if ${NODE-node} --test test/shader-compile.mjs > "$DOCS_OUT" 2>&1; then
    grep -E 'NOT EXERCISED HERE|^EXERCISED HERE' "$DOCS_OUT"
    echo "ok   test/shader-compile.mjs"
else
    cat "$DOCS_OUT"
    echo "FAIL test/shader-compile.mjs"; fail=1
fi
if ${NODE-node} --test test/manual-long-form.mjs > "$DOCS_OUT" 2>&1; then
    grep -E 'NOT EXERCISED HERE|^EXERCISED HERE' "$DOCS_OUT"
    echo "ok   test/manual-long-form.mjs"
else
    cat "$DOCS_OUT"
    echo "FAIL test/manual-long-form.mjs"; fail=1
fi
if ${NODE-node} --test test/shader-accessors.mjs > "$DOCS_OUT" 2>&1; then
    echo "ok   test/shader-accessors.mjs"
else
    cat "$DOCS_OUT"
    echo "FAIL test/shader-accessors.mjs"; fail=1
fi
if ${NODE-node} --test test/docs.mjs > "$DOCS_OUT" 2>&1; then
    grep -E 'NOT EXERCISED HERE|^EXERCISED HERE' "$DOCS_OUT"
    echo "ok   test/docs.mjs"
else
    cat "$DOCS_OUT"
    echo "FAIL test/docs.mjs"; fail=1
fi
# Output is kept and shown only on failure: when the index drifts, the
# useful part IS the list of names, and a pipe here would report the
# exit status of the pager instead of the test.
API_OUT="$T/api-index.out"
if ${NODE-node} test/api-index.mjs > "$API_OUT" 2>&1; then
    echo "ok   test/api-index.mjs"
else
    head -40 "$API_OUT"
    echo "FAIL test/api-index.mjs"; fail=1
fi
# The cache decides whether a compile is skipped, so a defect in its key
# hands back yesterday's artifact and calls it today's -- the one failure
# this suite cannot see from outside, because a stale artifact and a
# fresh one both just sit there being green.  Its own checks were not in
# this round until now: 185 lines deciding what counts as the same
# compile, and nothing checking them.
if ${NODE-node} test/compile-cache.mjs >/dev/null 2>&1; then
    echo "ok   test/compile-cache.mjs"
else
    ${NODE-node} test/compile-cache.mjs 2>&1 | tail -20
    echo "FAIL test/compile-cache.mjs"; fail=1
fi
# The two 2026-09-06 defects whose counterexample is a compile-time
# fact rather than a wrong value.  RED until they are fixed.
if ${NODE-node} test/defect-c01-c04-compile-time.mjs >/dev/null 2>&1; then
    echo "ok   test/defect-c01-c04-compile-time.mjs"
else
    ${NODE-node} test/defect-c01-c04-compile-time.mjs 2>&1 | tail -12
    echo "FAIL test/defect-c01-c04-compile-time.mjs"; fail=1
fi
if ${NODE-node} test/duplicate-top-level.mjs >/dev/null 2>&1; then
    echo "ok   test/duplicate-top-level.mjs"
else
    echo "FAIL test/duplicate-top-level.mjs"; fail=1
fi
if ${NODE-node} test/trig-single-supply.mjs >/dev/null 2>&1; then
    echo "ok   test/trig-single-supply.mjs"
else
    echo "FAIL test/trig-single-supply.mjs"; fail=1
fi
exit $fail
