# cdn.goeteia.dev

Versioned, immutable copies of the browser half of the Goeteia runtime,
plus the self-hosted compiler snapshot.  Built by `../build-cdn.sh`
from a tagged source tree; a directory here is never rebuilt in place.

    https://cdn.goeteia.dev/<version>/rt/web.mjs       loader: loadGoeteia, loadGoeteiaAuto, loadGoeteiaWorker, hasWasmGC
    https://cdn.goeteia.dev/<version>/rt/jsbridge.mjs  the js.* import bridge (web.mjs imports it)
    https://cdn.goeteia.dev/<version>/rt/worker.mjs    worker-side loader (web.mjs resolves it relative to itself)
    https://cdn.goeteia.dev/<version>/rt/sexpr.mjs     s-expression wire codec for pages that do not run Goeteia
    https://cdn.goeteia.dev/<version>/rt/react.mjs     embedding Goeteia components in a React tree
    https://cdn.goeteia.dev/<version>/goeteia.wasm  the compiler snapshot that built this version
    https://cdn.goeteia.dev/<version>/src/prelude.ss, lib/**.ss   the sources a browser-side compile feeds it
    https://cdn.goeteia.dev/<version>/manifest.json bytes, sha256 and SRI (sha384) for every file
    https://cdn.goeteia.dev/<version>/SHA256SUMS

Usage, from any page:

    <script type="module">
      import { loadGoeteiaAuto } from 'https://cdn.goeteia.dev/1.5.8/rt/web.mjs';
      loadGoeteiaAuto('./app.wasm', './app.js');   // wasm on WasmGC engines, else the --js build
    </script>

The Node-only tools (compile, run, dev, pack, verify, repl) are not
published here: they import node:fs and would fail at load in a
browser.  They ship in the npm package.

`cdn.goeteia.dev/<path>` and `goeteia.dev/cdn/<path>` are the same
bytes: the subdomain is a Cloudflare URL rewrite that prefixes `/cdn`
before the request reaches the site, so the immutable caching and
CORS headers declared for `/cdn/*` apply to both.
