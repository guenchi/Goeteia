// A loop started by one module instance must retire when ANOTHER
// instance calls fx-init! -- the live-page case: switching demos must
// not leave the previous demo's rAF loop running forever, pinning its
// instance and GL context.  A generation counter under __goeteia_*
// cannot do this: the bridge keeps that namespace private per
// instance, so each module would only ever see its own counter.
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { compileSource } from '../rt/compile.mjs';
import { makeJsBridge } from '../rt/jsbridge.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const build = tag =>
    compileSource(
        '(import (rnrs) (web js) (gfx fx) (gfx gl))\n' +
        '(fx-init! (js-get (js-global) "__c"))\n' +
        '(fx-ticks! (lambda (el dt)\n' +
        `  (js-method (js-get (js-global) "__log") "push" "${tag}")))\n`,
        { baseDir: root });

const log = [];
let rafs = [];
const glStub = new Proxy({}, { get: (_, p) =>
    /^[A-Z0-9_]+$/.test(p) ? 0x8000
    : /Parameter$/.test(p) ? () => 1
    : /^create/.test(p) ? () => ({})
    : /Location$/.test(p) ? () => 0
    : () => undefined });
globalThis.__log = log;
// Each run gets a canvas in a FRESH parent, the way a live page builds
// a new subtree per render.  Reusing one detached canvas made any scope
// keyed on what the run creates look shared -- this test passed against
// a change that reintroduced the leak until it mounted like the page.
const freshCanvas = () => ({ parentNode: { mark: 'new subtree' },
                             getContext: () => glStub });
globalThis.requestAnimationFrame = (cb) => rafs.push(cb);
const io = { write_byte() {}, read_byte: () => -1, path_byte() {},
             open_read: () => -1, open_write: () => -1,
             fread: () => -1, fwrite() {}, fclose() {} };
async function load(bytes) {
    globalThis.__c = freshCanvas();
    let ex;
    const { instance } = await WebAssembly.instantiate(
        bytes, { io, js: makeJsBridge(() => ex) });
    ex = instance.exports;
    globalThis.__goeteia_mem = ex.memory;
    ex.main();
}
const pump = () => { const cbs = rafs; rafs = []; cbs.forEach(cb => cb(16)); };

await load(await build('A'));
pump();
assert.deepEqual(log, ['A'], 'the first instance drives its own loop');

log.length = 0;
await load(await build('B'));         // a second instance takes the stage
pump(); pump();
assert.ok(!log.includes('A'),
    `the first instance's loop outlived its retirement: ${log.join(',')}`);
assert.ok(log.includes('B'), 'the second instance should be running');
console.log('PASS: fx-init! retires a loop started by another instance');
