#!/bin/sh
# Regenerate counter-single.html: a page shell around the mount
# section that bin/goeteia-mount.mjs assembles from counter.ss --
# the inline --js fallback plus the wasm reference, picked by
# loadGoeteiaAuto at load time.
set -e
cd "$(dirname "$0")/.."
{
cat <<'HEAD'
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Goeteia DOM counter — single file</title>
    <style>
      body { font-family: system-ui; text-align: center; margin-top: 4em; }
      #count { font-size: 4em; font-weight: 700; margin: .3em; }
      button { font-size: 1.4em; padding: .2em 1em; margin: 0 .3em; }
      #mode { color: #888; font-size: .9em; }
    </style>
  </head>
  <body>
    <h1>Goeteia counter</h1>
    <p>The same page as <code>counter.html</code>, self-contained: the
    <code>--js</code> compiled fallback rides inline, and the loader
    picks wasm or JS by engine support.  Append
    <code>?goeteia=js</code> to force the fallback.  Regenerate with
    <code>examples/mk-counter-single.sh</code>.</p>
    <div id="app"></div>
    <p id="mode"></p>
    <script type="module">
      import { hasWasmGC } from '../rt/web.mjs';
      const forced = new URLSearchParams(location.search).get('goeteia') === 'js';
      document.getElementById('mode').textContent =
        (!forced && hasWasmGC()) ? 'running: counter.wasm (WasmGC)' : 'running: inline JS fallback';
    </script>
HEAD
node bin/goeteia-mount.mjs examples/counter.ss --rt '../rt/web.mjs'
cat <<'TAIL'
  </body>
</html>
TAIL
} > examples/counter-single.html
echo "examples/counter-single.html regenerated"
