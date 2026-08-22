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
for t in test/*.ss; do
    want=$(head -1 "$t" | sed 's/^;; expect: //')
    $CAP ./bin/goeteiac "$t" "$T/test.wasm"; ec=$?
    if timed_out $ec; then
        echo "TIMEOUT $t (stage0 compile) after ${TLIMIT}s"; fail=1; continue
    elif [ $ec -ne 0 ]; then
        echo "FAIL $t (stage0 compile error)"; fail=1; continue
    fi
    got=$(run_one "$T/test.wasm" "$t"); ec=$?
    if timed_out $ec; then
        echo "TIMEOUT $t (stage0 run) after ${TLIMIT}s"; fail=1; continue
    fi
    if [ "$got" = "$want" ]; then
        echo "ok   $t"
    else
        echo "FAIL $t (stage0: want '$want', got '$got')"; fail=1
    fi
    if [ -f goeteia.wasm ]; then
        if ! ${NODE-node} rt/compile.mjs goeteia.wasm "$t" "$T/test1.wasm" 2>/dev/null; then
            echo "FAIL $t (stage1 compile error)"; fail=1; continue
        fi
        got=$(run_one "$T/test1.wasm" "$t"); ec=$?
        if timed_out $ec; then
            echo "TIMEOUT $t (stage1 run) after ${TLIMIT}s"; fail=1; continue
        fi
        if [ "$got" = "$want" ]; then
            echo "ok   $t (stage1)"
        else
            echo "FAIL $t (stage1: want '$want', got '$got')"; fail=1
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
    got=$(run_js "$T/test.js" "$t"); ec=$?
    if timed_out $ec; then
        echo "TIMEOUT $t (js run) after ${TLIMIT}s"; fail=1; continue
    fi
    if [ "$got" = "$want" ]; then
        echo "ok   $t (js)"
    else
        echo "FAIL $t (js: want '$want', got '$got')"; fail=1
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
if ${NODE-node} --test test/docs.mjs >/dev/null 2>&1; then
    echo "ok   test/docs.mjs"
else
    echo "FAIL test/docs.mjs"; fail=1
fi
if ${NODE-node} test/js-backend-procedure-identity.mjs >/dev/null 2>&1; then
    echo "ok   test/js-backend-procedure-identity.mjs"
else
    echo "FAIL test/js-backend-procedure-identity.mjs"; fail=1
fi
if ${NODE-node} test/trig-single-supply.mjs >/dev/null 2>&1; then
    echo "ok   test/trig-single-supply.mjs"
else
    echo "FAIL test/trig-single-supply.mjs"; fail=1
fi
exit $fail
