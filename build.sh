#!/bin/sh
# build.sh — recompile Goeteia page modules across the whole project.
#
# The dev server (rt/dev.mjs) watches the current directory and runs this
# on every save. A "page module" is any .ss that already has a sibling
# .wasm (i.e. something a page loads) — this covers examples/ today and
# any new page you add anywhere in the tree tomorrow, while skipping the
# compiler/prelude/library sources that are not standalone modules.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"

find "$DIR" \
  \( -name node_modules -o -name .git -o -name tmp \) -prune -o \
  -name '*.ss' -print | while IFS= read -r src; do
    wasm="${src%.ss}.wasm"
    [ -f "$wasm" ] || continue                 # only modules a page loads
    [ "$src" -nt "$wasm" ] || continue         # only if the source is newer
    echo "  compile ${src#$DIR/}"
    node "$DIR/bin/goeteia.mjs" compile "$src" "$wasm"
done
