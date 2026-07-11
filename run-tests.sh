#!/bin/sh
# Compile and run every test, with the Chez-hosted compiler (stage0)
# and, if schwasm-self.wasm is present, with the self-hosted compiler
# (stage1).  Each test's first line declares the expected output as
# ";; expect: <value>".
cd "$(dirname "$0")"
fail=0
run_one() { # wasmfile testfile
    input="${2%.ss}.input"
    if [ -f "$input" ]; then
        ${NODE-node} rt/run.mjs "$1" "$input"
    else
        ${NODE-node} rt/run.mjs "$1"
    fi
}
for t in test/*.ss; do
    want=$(head -1 "$t" | sed 's/^;; expect: //')
    if ! ./bin/schwasmc "$t" /tmp/schwasm-test.wasm; then
        echo "FAIL $t (stage0 compile error)"; fail=1; continue
    fi
    got=$(run_one /tmp/schwasm-test.wasm "$t")
    if [ "$got" = "$want" ]; then
        echo "ok   $t"
    else
        echo "FAIL $t (stage0: want '$want', got '$got')"; fail=1
    fi
    if [ -f schwasm-self.wasm ]; then
        if ! ${NODE-node} rt/compile.mjs schwasm-self.wasm "$t" /tmp/schwasm-test1.wasm 2>/dev/null; then
            echo "FAIL $t (stage1 compile error)"; fail=1; continue
        fi
        got=$(run_one /tmp/schwasm-test1.wasm "$t")
        if [ "$got" = "$want" ]; then
            echo "ok   $t (stage1)"
        else
            echo "FAIL $t (stage1: want '$want', got '$got')"; fail=1
        fi
    fi
done
exit $fail
