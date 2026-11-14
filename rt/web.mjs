// Copyright 2026 guenchi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Browser loader for compiled Goeteia modules, main thread: full DOM
// access through the js bridge.

import { makeJsBridge, callMain, jsBridgeStubs } from './jsbridge.mjs';

// Instantiate an already-compiled module against the DOM bridge and run
// its main.  Pages that compile Goeteia in the browser hold the bytes
// rather than a URL, so this is the half of loadGoeteia they need.
export async function runGoeteiaBytes(bytes) {
    let exportsRef = null;
    const io = {
        write_byte: b => loadGoeteia._out.push(b),
        read_byte: () => -1,
        path_byte: () => {}, open_read: () => -1, open_write: () => -1,
        fread: () => -1, fwrite: () => {}, fclose: () => {},
    };
    let instance;
    try {
        ({ instance } = await WebAssembly.instantiate(
            bytes, { io, js: makeJsBridge(() => exportsRef) }));
    } catch {
        // an engine that advertises WebAssembly.Suspending yet rejects
        // the import: retry with a pass-through await
        const js = makeJsBridge(() => exportsRef);
        js.await = p => p;
        ({ instance } = await WebAssembly.instantiate(bytes, { io, js }));
    }
    exportsRef = instance.exports;
    await callMain(instance.exports);
    return instance.exports;
}

// Compile Scheme source in the browser: the compiler module reads the
// text as its stdin and writes the module bytes as its stdout.  A page
// that ships sources instead of a binary -- "compiled by Goeteia in
// your browser" -- needs exactly this and nothing else.
export async function compileGoeteia(source, compilerUrl = 'goeteia.wasm') {
    const input = new TextEncoder().encode(source);
    const out = [];
    let pos = 0;
    const { instance } = await WebAssembly.instantiate(
        await (await fetch(compilerUrl)).arrayBuffer(),
        {
            io: {
                write_byte: b => out.push(b),
                read_byte: () => (pos < input.length ? input[pos++] : -1),
                path_byte: () => {}, open_read: () => -1, open_write: () => -1,
                fread: () => -1, fwrite: () => {}, fclose: () => {},
            },
            js: jsBridgeStubs,          // the compiler never calls out to JS
        });
    try {
        instance.exports.main();
    } catch (cause) {
        // Compiler diagnostics share stdout with successful module bytes.
        // Preserve them when main traps instead of reducing every source
        // error to the Wasm engine's unhelpful "unreachable" message.
        const output = new TextDecoder().decode(new Uint8Array(out)).trim();
        const error = new Error(
            output || `Goeteia: compile failed: ${cause.message}`);
        error.cause = cause;
        error.output = output;
        throw error;
    }
    if (out.length === 0) throw new Error('Goeteia: compile produced no output');
    return new Uint8Array(out);
}

// The whole browser-compiler cycle: fetch a source list in parallel,
// concatenate in order (dependencies before dependents -- the compiler
// splices each (library ...) and treats (import ...) as a no-op), and
// compile.  This is what a page that ships sources instead of a binary
// actually calls.
export async function compileGoeteiaFrom(urls, compilerUrl = 'goeteia.wasm') {
    const texts = await Promise.all(
        urls.map(u => fetch(u).then(r => {
            if (!r.ok) throw new Error(`Goeteia: ${u} not found`);
            return r.text();
        })));
    return compileGoeteia(texts.join('\n'), compilerUrl);
}

export async function loadGoeteia(url) {
    return runGoeteiaBytes(await (await fetch(url)).arrayBuffer());
}
loadGoeteia._out = [];
// A page-global handle: a define-js section (a JS-target Scheme
// program, e.g. capability-gating logic deciding whether a heavy
// module should load at all) has no other way to reach this loader,
// which lives in the glue's module scope.  Any wasm/auto section's
// glue runs before later scripts in document order, so the handle is
// set by the time such a section needs it.
globalThis.__goeteia_load = loadGoeteia;
globalThis.__goeteia_run = runGoeteiaBytes;
globalThis.__goeteia_compile = compileGoeteia;
globalThis.__goeteia_compile_from = compileGoeteiaFrom;

// Run a module in a Worker over an OffscreenCanvas: the render loop
// leaves the main thread entirely (a busy main thread no longer
// drops frames).  Input forwards as messages -- keys from the
// window, pointer events from the canvas -- and rt/worker.mjs
// re-dispatches them to the module's listeners.  The module finds
// its canvas at (js-get (js-global) "__goeteia_canvas").
// Does this engine run WasmGC?  Validate a minimal module carrying
// one struct type -- pre-GC engines reject the typecode
export function hasWasmGC() {
    try {
        return WebAssembly.validate(new Uint8Array(
            [0, 97, 115, 109, 1, 0, 0, 0, 1, 3, 1, 95, 0]));
    } catch { return false; }
}

const browserIO = () => ({
    write_byte: b => loadGoeteia._out.push(b),
    read_byte: () => -1,
    path_byte: () => {}, open_read: () => -1, open_write: () => -1,
    fread: () => -1, fwrite: () => {}, fclose: () => {},
});

// Run a --js compiled module from inline text (a single-file page
// carries it in an inert <script> tag).  The text is an ES module;
// scoping it through Function needs only the export keywords gone.
export function runGoeteiaInline(text) {
    const body = String(text).replace(/^export /gm, '');
    const main = new Function(body + '\nreturn main;')();
    return main(browserIO());
}

// The two-artifact entry: the wasm module when the engine has WasmGC,
// otherwise the --js compiled fallback.  `fallback` is either a CSS
// selector for an inert inline <script> tag (the single-file page,
// zero extra requests) or a .js/.mjs URL fetched only when actually
// needed -- the lazy shape: WasmGC users never download the fallback,
// and the file caches independently of the page.  ?goeteia=js forces
// the fallback, for testing it on a GC engine.
// how many times each fallback URL has been launched in this page
const launches = new Map();
export async function loadGoeteiaAuto(url, fallback = 'script[type="goeteia/js"]') {
    const forced = new URLSearchParams(location.search).get('goeteia') === 'js';
    if (!forced && hasWasmGC()) return loadGoeteia(url);
    if (/\.m?js([?#]|$)/.test(fallback)) {
        // The fallback is imported as a module, which needs no code made
        // from strings (a Content-Security-Policy without 'unsafe-eval'
        // allows it).  One URL imported twice is one module, and its
        // kernel's memory and FFI locals are module-scoped, so every
        // launch after the first imports the URL with a query of its own
        // and gets a runtime of its own.  When the import fails -- a
        // server that sends the file with a type a module may not have, a
        // scheme the engine will not import -- the old route runs: fetch
        // the text and run it with runGoeteiaInline, which needs eval.
        const href = new URL(fallback, location.href).href;
        const n = launches.get(href) || 0;
        launches.set(href, n + 1);
        let spec = href;
        if (n > 0) {
            const u = new URL(href);
            u.searchParams.set('goeteia-launch', String(n));
            spec = u.href;
        }
        let mod;
        try {
            mod = await import(spec);
        } catch (importError) {
            try {
                const response = await fetch(href);
                if (!response.ok)
                    throw new Error(`${href} not found`);
                return runGoeteiaInline(await response.text());
            } catch (oldError) {
                throw new Error(`Goeteia: importing ${spec} failed ` +
                                `(${importError.message}); fetching it and ` +
                                `running its text failed too ` +
                                `(${oldError.message})`);
            }
        }
        return mod.main(browserIO());
    }
    const tag = document.querySelector(fallback);
    if (!tag) throw new Error('no Goeteia fallback on this page');
    return runGoeteiaInline(tag.textContent);
}

export function loadGoeteiaWorker(url, canvas) {
    const off = canvas.transferControlToOffscreen();
    const worker = new Worker(new URL('./worker.mjs', import.meta.url),
                              { type: 'module' });
    worker.postMessage(
        { wasm: new URL(url, location.href).href, canvas: off }, [off]);
    const fwd = (kind, extra) =>
        worker.postMessage(Object.assign({ event: kind }, extra));
    window.addEventListener('keydown', e => fwd('keydown', { key: e.key }));
    window.addEventListener('keyup', e => fwd('keyup', { key: e.key }));
    for (const k of ['pointermove', 'pointerdown', 'pointerup', 'click'])
        canvas.addEventListener(k, e =>
            fwd(k, { offsetX: e.offsetX, offsetY: e.offsetY }));
    return worker;
}
