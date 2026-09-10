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
    # Rebuild when ANY source the artifact is derived from is newer,
    # not only the page's own. Comparing against one input let an edit
    # to an imported library leave the artifact in place, so the dev
    # server went on serving the previous picture -- and kept serving
    # it, because the timestamp that decided never moved.
    #
    # The page's own source is checked first because it costs nothing
    # and is the common case; the dependency list is asked for only
    # when that check says no. `deps` answers from the same walk the
    # compiler uses to inline those files, so the two cannot disagree.
    if [ "$src" -nt "$wasm" ]; then
        :
    else
        stale=
        for dep in $(node "$DIR/bin/goeteia.mjs" deps "$src"); do
            if [ "$dep" -nt "$wasm" ]; then stale=1; break; fi
        done
        [ -n "$stale" ] || continue
    fi
    echo "  compile ${src#$DIR/}"
    node "$DIR/bin/goeteia.mjs" compile "$src" "$wasm"
done
