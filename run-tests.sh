#!/bin/sh
# Compile and run every test, with the Chez-hosted compiler (stage0)
# and, if goeteia.wasm is present, with the self-hosted compiler
# (stage1).  Each test also compiles and runs on the JS target, whose
# emitted text must agree between hosts byte-for-byte.  Each test's
# first line declares the expected output as ";; expect: <value>".
cd "$(dirname "$0")"
fail=0
# enable JSPI (js-await suspension) when this node accepts the flag
JSPI=""
if ${NODE-node} --experimental-wasm-jspi -e 1 >/dev/null 2>&1; then
    JSPI="--experimental-wasm-jspi"
fi
run_one() { # wasmfile testfile
    input="${2%.ss}.input"
    if [ -f "$input" ]; then
        ${NODE-node} $JSPI rt/run.mjs "$1" "$input"
    else
        ${NODE-node} $JSPI rt/run.mjs "$1"
    fi
}
run_js() { # jsfile testfile
    input="${2%.ss}.input"
    if [ -f "$input" ]; then
        ${NODE-node} rt/runjs.mjs "$1" "$input"
    else
        ${NODE-node} rt/runjs.mjs "$1"
    fi
}
for t in test/*.ss; do
    want=$(head -1 "$t" | sed 's/^;; expect: //')
    if ! ./bin/goeteiac "$t" /tmp/goeteia-test.wasm; then
        echo "FAIL $t (stage0 compile error)"; fail=1; continue
    fi
    got=$(run_one /tmp/goeteia-test.wasm "$t")
    if [ "$got" = "$want" ]; then
        echo "ok   $t"
    else
        echo "FAIL $t (stage0: want '$want', got '$got')"; fail=1
    fi
    if [ -f goeteia.wasm ]; then
        if ! ${NODE-node} rt/compile.mjs goeteia.wasm "$t" /tmp/goeteia-test1.wasm 2>/dev/null; then
            echo "FAIL $t (stage1 compile error)"; fail=1; continue
        fi
        got=$(run_one /tmp/goeteia-test1.wasm "$t")
        if [ "$got" = "$want" ]; then
            echo "ok   $t (stage1)"
        else
            echo "FAIL $t (stage1: want '$want', got '$got')"; fail=1
        fi
        # both hosts must emit identical bytes from identical source
        if ! cmp -s /tmp/goeteia-test.wasm /tmp/goeteia-test1.wasm; then
            echo "FAIL $t (cross-host: stage0/stage1 bytes differ)"; fail=1
        fi
    fi
    # the JS target answers to the same oracle
    if ! ./bin/goeteiac --js "$t" /tmp/goeteia-test.js; then
        echo "FAIL $t (js compile error)"; fail=1; continue
    fi
    got=$(run_js /tmp/goeteia-test.js "$t")
    if [ "$got" = "$want" ]; then
        echo "ok   $t (js)"
    else
        echo "FAIL $t (js: want '$want', got '$got')"; fail=1
    fi
    if [ -f goeteia.wasm ]; then
        if ! ${NODE-node} rt/compile.mjs --js goeteia.wasm "$t" /tmp/goeteia-test1.js 2>/dev/null; then
            echo "FAIL $t (stage1 js compile error)"; fail=1; continue
        fi
        if ! cmp -s /tmp/goeteia-test.js /tmp/goeteia-test1.js; then
            echo "FAIL $t (cross-host: stage0/stage1 JS text differs)"; fail=1
        fi
    fi
done
if ${NODE-node} test/js-backend-arity.mjs; then
    echo "ok   test/js-backend-arity.mjs"
else
    echo "FAIL test/js-backend-arity.mjs"; fail=1
fi
exit $fail
