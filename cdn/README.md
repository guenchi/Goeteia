# goeteia.dev/cdn

Versioned, immutable copies of the browser half of the Goeteia runtime,
plus the self-hosted compiler snapshot.  Built by `../build-cdn.sh`
from a tagged source tree; a directory here is never rebuilt in place.

    https://goeteia.dev/cdn/<version>/web.mjs       loader: loadGoeteia, loadGoeteiaAuto, loadGoeteiaWorker, hasWasmGC
    https://goeteia.dev/cdn/<version>/jsbridge.mjs  the js.* import bridge (web.mjs imports it)
    https://goeteia.dev/cdn/<version>/worker.mjs    worker-side loader (web.mjs resolves it relative to itself)
    https://goeteia.dev/cdn/<version>/sexpr.mjs     s-expression wire codec for pages that do not run Goeteia
    https://goeteia.dev/cdn/<version>/react.mjs     embedding Goeteia components in a React tree
    https://goeteia.dev/cdn/<version>/goeteia.wasm  the compiler snapshot that built this version
    https://goeteia.dev/cdn/<version>/manifest.json bytes, sha256 and SRI (sha384) for every file
    https://goeteia.dev/cdn/<version>/SHA256SUMS

Usage, from any page:

    <script type="module">
      import { loadGoeteiaAuto } from 'https://goeteia.dev/cdn/1.5.8/web.mjs';
      loadGoeteiaAuto('./app.wasm', './app.js');   // wasm on WasmGC engines, else the --js build
    </script>

The Node-only tools (compile, run, dev, pack, verify, repl) are not
published here: they import node:fs and would fail at load in a
browser.  They ship in the npm package.
