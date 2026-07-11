#!/bin/sh
# Compile and run every test; each test's first line declares the
# expected printed result as ";; expect: <value>".
cd "$(dirname "$0")"
fail=0
for t in test/*.ss; do
    want=$(head -1 "$t" | sed 's/^;; expect: //')
    if ! ./bin/schwasmc "$t" /tmp/schwasm-test.wasm; then
        echo "FAIL $t (compile error)"; fail=1; continue
    fi
    input="${t%.ss}.input"
    if [ -f "$input" ]; then
        got=$(${NODE-node} rt/run.mjs /tmp/schwasm-test.wasm "$input")
    else
        got=$(${NODE-node} rt/run.mjs /tmp/schwasm-test.wasm)
    fi
    if [ "$got" = "$want" ]; then
        echo "ok   $t"
    else
        echo "FAIL $t (want '$want', got '$got')"
        fail=1
    fi
done
exit $fail
