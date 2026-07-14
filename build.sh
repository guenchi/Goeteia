#!/bin/sh
# Rebuild every page from its Scheme source (site/*.ss) with the
# self-hosted compiler. Run from the website root; each program reads
# its site/<page>.css and writes <page>.html.
set -e
cd "$(dirname "$0")"
for p in index why agent manual; do
    node rt/compile.mjs goeteia.wasm "site/$p.ss" "/tmp/$p.wasm"
    node rt/run.mjs "/tmp/$p.wasm"
    echo "built $p.html ($(wc -c < "$p.html" | tr -d ' ') bytes)"
done
# the Why page's browser-side typeset effect, precompiled
node rt/compile.mjs goeteia.wasm why-fx.ss why-fx.wasm
echo "built why-fx.wasm ($(wc -c < why-fx.wasm | tr -d ' ') bytes)"
