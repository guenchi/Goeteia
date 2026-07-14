// The self-rendering homepage: Goeteia compiles the page's own Scheme
// source in your browser and mounts the result live. Editing the source
// and pressing Run recompiles (~15 ms) and re-renders in place.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import { makeJsBridge, jsBridgeStubs } from './rt/jsbridge.mjs';

// the library sources, prefetched once at boot; each compile resolves
// the source's (import ...) forms against this set and inlines ONLY
// what the source reaches (mirrors rt/compile.mjs) -- a demo that
// never touches (gfx gpu) no longer pays to compile it
const LIB_FILES = [
    'src/prelude.ss',
    'lib/web/js.ss',
    'lib/web/dom.ss',
    'lib/web/reactive.ss',
    'lib/web/sx.ss',
    'lib/web/html.ss',
    'lib/gfx/glsl.ss',
    'lib/gfx/gl.ss',
    'lib/web/typeset.ss',
    'lib/web/canvas.ss',
    'lib/web/glyphs.ss',
    'lib/gfx/mat.ss',
    'lib/gfx/mesh.ss',
    'lib/gfx/fx.ss',
    'lib/gfx/post.ss',
    'lib/gfx/gpu.ss',
];

const enc = new TextEncoder();
const stubs = {
    path_byte: () => {}, open_read: () => -1, open_write: () => -1,
    fread: () => -1, fwrite: () => {}, fclose: () => {},
};

let compilerBytes = null;
let preludeText = null;
const libSources = new Map();           // 'lib/web/sx.ss' -> source text

export async function boot() {
    const [wasm, prelude, ...texts] = await Promise.all([
        fetch('goeteia.wasm').then(r => {
            if (!r.ok) throw new Error('goeteia.wasm not found');
            return r.arrayBuffer();
        }),
        ...LIB_FILES.map(p => fetch(p).then(r => r.text())),
    ]);
    compilerBytes = wasm;
    preludeText = prelude;              // LIB_FILES[0] is the prelude
    LIB_FILES.slice(1).forEach((p, i) => libSources.set(p, texts[i]));
}

// ---- import resolution (the browser copy of rt/compile.mjs's) ----
// Top-level (import (a b) ...) forms pull in lib/a/b.ss, a single
// (library ...) form per file, dependencies first, each once.

function topLevelSpans(text) {
    const spans = [];
    let depth = 0, start = -1;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (c === ';') { while (i < text.length && text[i] !== '\n') i++; continue; }
        if (c === '"') { i++; while (i < text.length && text[i] !== '"') { if (text[i] === '\\') i++; i++; } continue; }
        if (c === '#' && text[i + 1] === '\\') { i += 2; continue; }
        if (c === '(') { if (depth === 0) start = i; depth++; }
        else if (c === ')') { depth--; if (depth === 0) spans.push([start, i + 1]); }
    }
    return spans;
}

function parseSexpr(text) {             // just enough for import clauses
    let i = 0;
    function skip() { while (i < text.length && /[\s]/.test(text[i])) i++; }
    function one() {
        skip();
        if (text[i] === '(') {
            i++;
            const items = [];
            for (skip(); text[i] !== ')'; skip()) items.push(one());
            i++;
            return items;
        }
        const start = i;
        while (i < text.length && !/[\s()]/.test(text[i])) i++;
        return text.slice(start, i);
    }
    return one();
}

const parseSpecs = form => parseSexpr(form).slice(1);
const specTarget = spec =>
    ['only', 'except', 'rename', 'prefix'].includes(spec[0]) ? spec[1] : spec;
const specAliases = spec =>
    spec[0] !== 'rename' ? ''
    : spec.slice(2).map(pr => `(define ${pr[1]} ${pr[0]})`).join('\n');

function libraryImports(text) {         // the (import ...) at depth 1
    let depth = 0, start = -1;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (c === ';') { while (i < text.length && text[i] !== '\n') i++; continue; }
        if (c === '"') { i++; while (i < text.length && text[i] !== '"') { if (text[i] === '\\') i++; i++; } continue; }
        if (c === '#' && text[i + 1] === '\\') { i += 2; continue; }
        if (c === '(') { if (depth === 1) start = i; depth++; }
        else if (c === ')') {
            depth--;
            if (depth === 1 && start >= 0) {
                const clause = text.slice(start, i + 1);
                if (/^\(\s*import[\s)]/.test(clause)) return parseSpecs(clause);
            }
        }
    }
    return [];
}

// (%loc "file" line) markers map stream lines back to source lines,
// so compile errors can say file:line
const locMark = (file, line) => `\n(%loc ${JSON.stringify(file)} ${line})\n`;
function lineAt(text, idx) {
    let n = 1;
    for (let i = 0; i < idx && i < text.length; i++)
        if (text[i] === '\n') n++;
    return n;
}

function loadLibrary(spec, visited) {
    // (rnrs ...) and (goeteia ...) come from the prelude
    if (spec[0] === 'rnrs' || spec[0] === 'goeteia') return '';
    const key = spec.join('/');
    if (visited.has(key)) return '';
    visited.add(key);
    const p = 'lib/' + spec.join('/') + '.ss';
    const text = libSources.get(p);
    if (text === undefined)
        throw new Error(`library not found: (${spec.join(' ')})`);
    const deps = libraryImports(text)
        .map(s => loadLibrary(specTarget(s), visited) + '\n' + specAliases(s))
        .join('\n');
    return deps + locMark(p, 1) + text;
}

function resolveImports(text, file) {
    const visited = new Set();
    let result = locMark(file, 1);
    let at = 0;
    for (const [start, end] of topLevelSpans(text)) {
        const form = text.slice(start, end);
        if (/^\(\s*import[\s)]/.test(form)) {
            result += text.slice(at, start);
            result += parseSpecs(form)
                .map(spec => loadLibrary(specTarget(spec), visited)
                             + '\n' + specAliases(spec))
                .join('\n');
            result += locMark(file, lineAt(text, end));
            at = end;
        }
    }
    return result + text.slice(at);
}

// compile Scheme source to a wasm module (pure; no DOM, safe to call often)
export async function compile(userSource) {
    const input = enc.encode(locMark('prelude', 1) + preludeText + '\n'
                             + resolveImports(userSource, 'editor'));
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
    // expose the staging memory so (gfx gl) can build typed-array views
    if (instance.exports.memory) globalThis.__goeteia_mem = instance.exports.memory;
    ex.main();                                  // mounts into #live
    return { compileMs: ms, bytes: wasm.length };
}
