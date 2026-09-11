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
ERRF="$T/stderr.txt"
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

# The verdict for one run of one test, from BOTH of the things a run
# produces.  Matching stdout used to be the whole test: a program
# that printed the expected answer and then exited 7 was reported ok,
# and the round exited 0.  A process that answers correctly and dies is
# not a process that passed -- it is one whose answer arrived before
# whatever killed it, and the two are only the same if nothing after the
# answer mattered.  So the exit code is a second, independent condition,
# and the message says which of the two failed.
verdict() { # stage want got exitcode -> prints, sets fail
    _stage=$1; _want=$2; _got=$3; _ec=$4
    if [ "$_got" = "$_want" ] && [ "$_ec" -eq 0 ]; then
        # stage0's ok line carries no suffix, as it always has.  Not
        # cosmetic: the gate's reader and three months of logs are
        # written against these exact lines, and a refactor that made
        # every passing line different would be a change to the output
        # of the whole suite smuggled in with a change to one condition.
        if [ "$_stage" = stage0 ]; then echo "ok   $t"; else echo "ok   $t ($_stage)"; fi
        return 0
    fi
    if [ "$_got" = "$_want" ]; then
        echo "FAIL $t ($_stage: the answer was right and the process exited $_ec)"
    else
        echo "FAIL $t ($_stage: want '$_want', got '$_got')"
        say_if_crashed "$_ec"
    fi
    fail=1
}

# Every .mjs test goes through here, and through $CAP.  Thirty copies of
# the same four lines is how two thirds of this script's surface came to
# have no timeout on it at all: the bound was added to the .ss runs, and
# each new .mjs check was written by copying the block above it, which
# did not have one.  A hanging .mjs test STALLED the whole round
# rather than failing it -- the exact failure the cap exists for.
#
# Some of these print a transcript worth seeing when they fail and
# nothing worth seeing when they pass; `quiet` is that case.
run_mjs() { # testfile [quiet]
    if [ "$2" = quiet ]; then
        $CAP ${NODE-node} "$1" >/dev/null 2>&1; ec=$?
    else
        $CAP ${NODE-node} "$1"; ec=$?
    fi
    if [ $ec -eq 0 ]; then
        echo "ok   $1"
    else
        if [ "$2" = quiet ]; then $CAP ${NODE-node} "$1" 2>&1 | tail -20; fi
        if timed_out $ec; then
            echo "TIMEOUT $1 after ${TLIMIT}s"
        else
            echo "FAIL $1"
        fi
        fail=1
    fi
}
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

# stderr is kept, not thrown away.  A callback that raises cannot
# carry the error back into the host, so lib/web/js.ss answers undefined
# and REPORTS to the console -- deliberately, because an error on every
# animation frame is otherwise invisible.  That report went to stderr,
# and this script compares stdout, so the report nobody reads was being
# printed fifty-one times a round while every test involved passed.
# A diagnostic that is written and never read is worse than none: it
# costs the run its cycles and buys a belief that someone is watching.
run_one() { # wasmfile testfile   -- stdout to the caller, stderr to $ERRF
    input="${2%.ss}.input"
    if [ -f "$input" ]; then
        $CAP ${NODE-node} $JSPI rt/run.mjs "$1" "$input" 2>"$ERRF"
    else
        $CAP ${NODE-node} $JSPI rt/run.mjs "$1" 2>"$ERRF"
    fi
}

# What a run wrote to stderr that is a REPORT rather than a diagnostic
# of a failure the verdict already covers.  Counted per run and named,
# so a residual one is attributable to the test that produced it.
check_stderr() { # stage
    [ -s "$ERRF" ] || return 0
    # `grep -c` prints 0 AND exits non-zero when nothing matches, so
    # `|| echo 0` fired as well and n became two lines -- "0\n0" -- which
    # is not an integer, so the test below errored, did not return, and
    # fell through to print a failure.  The fallback triggered
    # precisely when it was not needed, and twelve passing tests were
    # reported as failing with `0\n0 callback error(s)`.
    #
    # It survived because this path had only ever been exercised WITH
    # a report present.  A check needs a case where it must stay silent
    # as much as one where it must speak, and the silent case is the one
    # nobody thinks to write.
    n=$(grep -c "callback error:\|callback raise:" "$ERRF" 2>/dev/null) || n=0
    [ "$n" -eq 0 ] && return 0
    echo "FAIL $t ($1: $n callback error(s) reported to the console)"
    grep "callback error:\|callback raise:" "$ERRF" | sort -u | head -3 \
        | sed 's/^/       /'
    fail=1
}
run_js() { # jsfile testfile
    input="${2%.ss}.input"
    if [ -f "$input" ]; then
        $CAP ${NODE-node} rt/runjs.mjs "$1" "$input" 2>"$ERRF"
    else
        $CAP ${NODE-node} rt/runjs.mjs "$1" 2>"$ERRF"
    fi
}
# GOETEIA_TESTS narrows the loop to named files, so a change to the
# verdict machinery can be exercised on one test instead of all of
# them.  Unset -- which is how the gate runs it -- it is every test.
# A name in GOETEIA_TESTS that is not a file used to reach the
# compiler, which failed to open it, and the round printed
# `(stage0 compile error)` -- so a test that DOES NOT EXIST read exactly
# like a test that failed.  Measured: a session put an invented filename
# in this variable and spent time reading the resulting red as a defect.
# The two are different facts and now say different things.
for t in ${GOETEIA_TESTS-test/*.ss}; do
    if [ ! -f "$t" ]; then
        echo "FAIL $t (no such file -- named in GOETEIA_TESTS but not on disk)"
        fail=1; continue
    fi
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
    verdict stage0 "$want" "$got" "$ec"
    check_stderr stage0
    if [ -f goeteia.wasm ]; then
        $CAP ${NODE-node} rt/compile.mjs goeteia.wasm "$t" "$T/test1.wasm" 2>/dev/null; ec=$?
        if timed_out $ec; then
            echo "TIMEOUT $t (stage1 compile) after ${TLIMIT}s"; fail=1; continue
        elif [ $ec -ne 0 ]; then
            echo "FAIL $t (stage1 compile error)"; fail=1; continue
        fi
        raw=$(run_one "$T/test1.wasm" "$t"); ec=$?; lift_notes "$raw"
        if timed_out $ec; then
            echo "TIMEOUT $t (stage1 run) after ${TLIMIT}s"; fail=1; continue
        fi
        verdict stage1 "$want" "$got" "$ec"
        check_stderr stage1
        # both hosts must emit identical bytes from identical source
        if ! cmp -s "$T/test.wasm" "$T/test1.wasm"; then
            echo "FAIL $t (cross-host: stage0/stage1 bytes differ)"; fail=1
        fi
    fi
    # the JS target answers to the same oracle
    if ! $CAP ./bin/goeteiac --js "$t" "$T/test.js"; then
        echo "FAIL $t (js compile error)"; fail=1; continue
    fi
    raw=$(run_js "$T/test.js" "$t"); ec=$?; lift_notes "$raw"
    if timed_out $ec; then
        echo "TIMEOUT $t (js run) after ${TLIMIT}s"; fail=1; continue
    fi
    verdict js "$want" "$got" "$ec"
    check_stderr js
    if [ -f goeteia.wasm ]; then
        $CAP ${NODE-node} rt/compile.mjs --js goeteia.wasm "$t" "$T/test1.js" 2>/dev/null; ec=$?
        if timed_out $ec; then
            echo "TIMEOUT $t (stage1 js compile) after ${TLIMIT}s"; fail=1; continue
        elif [ $ec -ne 0 ]; then
            echo "FAIL $t (stage1 js compile error)"; fail=1; continue
        fi
        if ! cmp -s "$T/test.js" "$T/test1.js"; then
            echo "FAIL $t (cross-host: stage0/stage1 JS text differs)"; fail=1
        fi
    fi
done
run_mjs test/js-backend-division.mjs
run_mjs test/js-backend-bounds.mjs
run_mjs test/run-errors.mjs
run_mjs test/gltf-p1.mjs
run_mjs test/glb-p1.mjs
run_mjs test/js-backend-arity.mjs
run_mjs test/js-backend-exports.mjs
run_mjs test/js-backend-memory-bounds.mjs
run_mjs test/js-backend-fl-conversion.mjs
run_mjs test/js-backend-flonum-types.mjs
run_mjs test/js-backend-pair-types.mjs
run_mjs test/js-backend-i31-types.mjs
run_mjs test/js-backend-collection-types.mjs
run_mjs test/js-backend-tco.mjs
run_mjs test/js-backend-jspi.mjs
if $CAP ${NODE-node} test/jsbridge-instance.mjs >/dev/null 2>&1; then
    echo "ok   test/jsbridge-instance.mjs"
else
    echo "FAIL test/jsbridge-instance.mjs"; fail=1
fi
if $CAP ${NODE-node} test/fx-loop-generation.mjs >/dev/null 2>&1; then
    echo "ok   test/fx-loop-generation.mjs"
else
    echo "FAIL test/fx-loop-generation.mjs"; fail=1
fi
if $CAP ${NODE-node} test/fx-loop-coexistence.mjs >/dev/null 2>&1; then
    echo "ok   test/fx-loop-coexistence.mjs"
else
    echo "FAIL test/fx-loop-coexistence.mjs"; fail=1
fi
if $CAP ${NODE-node} test/web-compile-diagnostics.mjs >/dev/null 2>&1; then
    echo "ok   test/web-compile-diagnostics.mjs"
else
    echo "FAIL test/web-compile-diagnostics.mjs"; fail=1
fi
if $CAP ${NODE-node} test/reader-diagnostics.mjs >/dev/null 2>&1; then
    echo "ok   test/reader-diagnostics.mjs"
else
    echo "FAIL test/reader-diagnostics.mjs"; fail=1
fi
if $CAP ${NODE-node} test/web-external-fallback-fresh.mjs >/dev/null 2>&1; then
    echo "ok   test/web-external-fallback-fresh.mjs"
else
    echo "FAIL test/web-external-fallback-fresh.mjs"; fail=1
fi
if $CAP ${NODE-node} test/glyphs-listener-cleanup.mjs >/dev/null 2>&1; then
    echo "ok   test/glyphs-listener-cleanup.mjs"
else
    echo "FAIL test/glyphs-listener-cleanup.mjs"; fail=1
fi
if $CAP ${NODE-node} test/glyphs-loop-generation.mjs >/dev/null 2>&1; then
    echo "ok   test/glyphs-loop-generation.mjs"
else
    echo "FAIL test/glyphs-loop-generation.mjs"; fail=1
fi
if $CAP ${NODE-node} test/glyphs-scope-dispose.mjs >/dev/null 2>&1; then
    echo "ok   test/glyphs-scope-dispose.mjs"
else
    echo "FAIL test/glyphs-scope-dispose.mjs"; fail=1
fi
run_mjs test/dev-nocache.mjs
run_mjs test/web-fs-nofs.mjs
run_mjs test/args.mjs
run_mjs test/determinism.mjs
run_mjs test/raster-diff.mjs
run_mjs test/verify.mjs
run_mjs test/pack.mjs
run_mjs test/llm-substrate.mjs
if $CAP ${NODE-node} --test test/sexpr-mjs.mjs >/dev/null 2>&1; then
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
if $CAP ${NODE-node} --test test/shader-compile.mjs > "$DOCS_OUT" 2>&1; then
    grep -E 'NOT EXERCISED HERE|^EXERCISED HERE' "$DOCS_OUT"
    echo "ok   test/shader-compile.mjs"
else
    cat "$DOCS_OUT"
    echo "FAIL test/shader-compile.mjs"; fail=1
fi
# The first check that judges a shader by what it PUTS ON THE SCREEN
# rather than by whether it compiles.  Stands down loudly without a
# browser, like the one above.
if $CAP ${NODE-node} --test test/gfx-tint-alpha.mjs > "$DOCS_OUT" 2>&1; then
    grep -E 'NOT EXERCISED HERE' "$DOCS_OUT" || true
    echo "ok   test/gfx-tint-alpha.mjs"
else
    cat "$DOCS_OUT"
    echo "FAIL test/gfx-tint-alpha.mjs"; fail=1
fi
if $CAP ${NODE-node} --test test/manual-long-form.mjs > "$DOCS_OUT" 2>&1; then
    grep -E 'NOT EXERCISED HERE|^EXERCISED HERE' "$DOCS_OUT"
    echo "ok   test/manual-long-form.mjs"
else
    cat "$DOCS_OUT"
    echo "FAIL test/manual-long-form.mjs"; fail=1
fi
if $CAP ${NODE-node} --test test/shader-accessors.mjs > "$DOCS_OUT" 2>&1; then
    echo "ok   test/shader-accessors.mjs"
else
    cat "$DOCS_OUT"
    echo "FAIL test/shader-accessors.mjs"; fail=1
fi
if $CAP ${NODE-node} --test test/docs.mjs > "$DOCS_OUT" 2>&1; then
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
if $CAP ${NODE-node} test/api-index.mjs > "$API_OUT" 2>&1; then
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
run_mjs test/compile-cache.mjs quiet
# The two 2026-09-06 defects whose counterexample is a compile-time
# fact rather than a wrong value.  Both are green now and kept as
# regression guards; this line said "RED until they are fixed" long
# after they were, which is the same decay the cells' own markers had.
run_mjs test/gfx-gpu-attrs.mjs
run_mjs test/defect-c01-c04-compile-time.mjs quiet
if $CAP ${NODE-node} test/duplicate-top-level.mjs >/dev/null 2>&1; then
    echo "ok   test/duplicate-top-level.mjs"
else
    echo "FAIL test/duplicate-top-level.mjs"; fail=1
fi
if $CAP ${NODE-node} test/trig-single-supply.mjs >/dev/null 2>&1; then
    echo "ok   test/trig-single-supply.mjs"
else
    echo "FAIL test/trig-single-supply.mjs"; fail=1
fi

# Three cells added on 2026-09-09.  They sat in test/ for hours
# without running, which is what the check below is for.
for m in test/macro-toplevel-hygiene.mjs \
         test/defect-r02-driver-block-comment.mjs \
         test/cdp-teardown.mjs \
         test/defect-library-export-unchecked.mjs \
         test/defect-r03-r04-repl.mjs \
         test/defect-r09-worker-listener-revocation.mjs \
         test/defect-d01-doc-uv-offset.mjs \
         test/ascii-only.mjs \
         test/defect-v01-shader-check-can-vanish-unnoticed.mjs \
         test/c02-product-fn-specs.mjs \
         test/c02-product-trampoline.mjs \
         test/c02-product-float-emission.mjs \
         test/c02-product-int-emission.mjs \
         test/spec-product-unshadowed-forwarding.mjs \
         test/expected-fail-markers-are-honest.mjs \
         test/spec-product-unshadowed-operator-position.mjs \
         test/defect-spec-candidate-by-name.mjs \
         test/defect-dce-binder-counts-as-reference.mjs \
         test/defect-spec-prelude-binder-collides-with-user-name.mjs \
         test/spec-scan-binding-forms.mjs \
         test/dce-binding-forms.mjs \
         test/prelude-survives-primitive-redefinition.mjs \
         test/intrinsic-head-costs-nothing.mjs \
         test/js-lowered-head-costs-nothing.mjs \
         test/import-refusals.mjs \
         test/import-unbound-reference.mjs \
         test/import-legal-programs.mjs \
         test/embed-body-clause-inheritance.mjs \
         test/defect-import-rule-holes.mjs \
         test/defect-prelude-procedure-excluded.mjs \
         test/source-has-no-duplicate-toplevel-define.mjs \
         test/reader-exact-exponent-cost.mjs \
         test/defect-renamed-syntax-and-literals.mjs \
         test/defect-b01-build-ignores-library-deps.mjs; do
    if $CAP ${NODE-node} --test "$m" >/dev/null 2>&1; then
        echo "ok   $m"
    else
        echo "FAIL $m"; fail=1
    fi
done

# EVERY test/*.mjs MUST BE NAMED IN THIS FILE.
#
# The .ss cells are a glob and a new one runs the moment it lands.  The
# .mjs cells are named one at a time, and a list by name cannot shout
# for what is missing from it: on 2026-09-09 three .mjs cells were
# written, committed, reported as delivered, and never run.  One of
# them was the hygiene guard -- the cell whose whole job is to fail if
# a fix reaches too far -- so for several hours a fix could have broken
# hygiene and nothing in the gate would have said a word.
#
# This checks that each file is MENTIONED, not that it ran.  That is
# weaker than it sounds only in a way nobody does by accident: naming a
# file here without running it takes deliberate effort, while adding a
# file to test/ and forgetting this list is one keystroke.  -> It covers
# the failure that happened, and it says which one it covers.
for m in test/*.mjs; do
    grep -q "$m" "$0" || {
        echo "FAIL $m (exists in test/ but is not named in run-tests.sh -- it never runs)"
        fail=1
    }
done

exit $fail
