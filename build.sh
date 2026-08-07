#!/bin/sh
# Rebuild every page from its Scheme source (site/*.ss) with the
# self-hosted compiler. Run from the website root; each program reads
# its site/<page>.css and writes <page>.html.  A page's browser-side
# half lives in a mount point inside its source, so the generator
# emits any .wasm it needs (why.ss writes why-fx.wasm) -- no separate
# compile step, no hand-written loader script.
set -e
cd "$(dirname "$0")"
for p in index why 3d agent manual; do
    node rt/compile.mjs goeteia.wasm "site/$p.ss" "/tmp/$p.wasm"
    node rt/run.mjs "/tmp/$p.wasm"
    echo "built $p.html ($(wc -c < "$p.html" | tr -d ' ') bytes)"
done
