// The self-rendering homepage: Goeteia compiles the page's own Scheme
// source in your browser and mounts the result live. Editing the source
// and pressing Run recompiles (~15 ms) and re-renders in place.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import { makeJsBridge, jsBridgeStubs } from './rt/jsbridge.mjs';

// prelude + web libraries, concatenated ahead of the user's source; the
// compiler splices each (library ...) and treats (import ...) as a no-op,
// so the imports in the source resolve against these definitions
const LIB_FILES = [
    'src/prelude.ss',
    'lib/web/js.ss',
    'lib/web/dom.ss',
    'lib/web/reactive.ss',
    'lib/web/sx.ss',
    'lib/web/html.ss',
    'lib/web/glsl.ss',
    'lib/web/gl.ss',
    'lib/web/typeset.ss',
    'lib/web/typeset/canvas.ss',
    'lib/web/mat.ss',
    'lib/web/mesh.ss',
    'lib/web/fx.ss',
    'lib/web/post.ss',
    'lib/web/gpu.ss',
];

const enc = new TextEncoder();
const stubs = {
    path_byte: () => {}, open_read: () => -1, open_write: () => -1,
    fread: () => -1, fwrite: () => {}, fclose: () => {},
};

let compilerBytes = null;
let libText = null;

export async function boot() {
    const [wasm, ...texts] = await Promise.all([
        fetch('goeteia.wasm').then(r => {
            if (!r.ok) throw new Error('goeteia.wasm not found');
            return r.arrayBuffer();
        }),
        ...LIB_FILES.map(p => fetch(p).then(r => r.text())),
    ]);
    compilerBytes = wasm;
    libText = texts.join('\n');
}

// compile Scheme source to a wasm module (pure; no DOM, safe to call often)
export async function compile(userSource) {
    const input = enc.encode(libText + '\n' + userSource);
    const out = [];
    let pos = 0;
    const { instance } = await WebAssembly.instantiate(compilerBytes, {
        io: {
            write_byte: b => out.push(b),
            read_byte: () => (pos < input.length ? input[pos++] : -1),
            ...stubs,
        },
        js: jsBridgeStubs,          // the compiler itself never calls JS
    });
    const t0 = performance.now();
    instance.exports.main();
    const t1 = performance.now();
    if (out.length === 0) throw new Error('compile produced no output');
    return { wasm: new Uint8Array(out), ms: t1 - t0 };
}

// compile + instantiate against a real DOM bridge + run: the module's
// main() builds DOM through (web dom)/(web sx). Runs on the main thread
// because Workers have no DOM. `liveEl` is cleared first (unmount).
export async function render(userSource, liveEl) {
    const { wasm, ms } = await compile(userSource);
    liveEl.textContent = '';                    // unmount the previous render
    let ex;
    const io = { write_byte: () => {}, read_byte: () => -1, ...stubs };
    let instance;
    try {
        ({ instance } = await WebAssembly.instantiate(wasm, {
            io, js: makeJsBridge(() => ex),
        }));
    } catch (e) {
        // engine advertised WebAssembly.Suspending but rejected it as an
        // import ("js:await must be callable"); retry with a plain no-op await
        const js = makeJsBridge(() => ex);
        js.await = p => p;
        ({ instance } = await WebAssembly.instantiate(wasm, { io, js }));
    }
    ex = instance.exports;
    // expose the staging memory so (web gl) can build typed-array views
    if (instance.exports.memory) globalThis.__goeteia_mem = instance.exports.memory;
    ex.main();                                  // mounts into #live
    return { compileMs: ms, bytes: wasm.length };
}
