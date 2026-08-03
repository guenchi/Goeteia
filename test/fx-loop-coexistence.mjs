// Two widgets that pass an EXPLICIT owner to fx-init! retire only their
// own loops: reinitializing one leaves the other animating.  The owner
// has to be a node that outlives the runs -- these hosts stand in for a
// container the page keeps.  (Without an owner the scope is global, so
// any init retires every loop; that default is what stops a live page
// from stacking a zombie loop per demo switch, and fx-loop-generation
// pins it.)
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { compileSource } from '../rt/compile.mjs';
import { makeJsBridge } from '../rt/jsbridge.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const build = tag => compileSource(
    '(import (rnrs) (web js) (gfx fx) (gfx gl))\n' +
    '(fx-init! (js-get (js-global) "__c") (js-get (js-global) "__owner"))\n' +
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
const hostA = {};
const hostB = {};
const canvas = parentNode => ({ parentNode, getContext: () => glStub });

globalThis.__log = log;
globalThis.requestAnimationFrame = cb => rafs.push(cb);
const io = { write_byte() {}, read_byte: () => -1, path_byte() {},
             open_read: () => -1, open_write: () => -1,
             fread: () => -1, fwrite() {}, fclose() {} };
async function load(bytes, target, owner) {
    globalThis.__c = target;
    globalThis.__owner = owner;
    let ex;
    const { instance } = await WebAssembly.instantiate(
        bytes, { io, js: makeJsBridge(() => ex) });
    ex = instance.exports;
    globalThis.__goeteia_mem = ex.memory;
    ex.main();
}
const pump = () => { const cbs = rafs; rafs = []; cbs.forEach(cb => cb(16)); };

await load(await build('A'), canvas(hostA), hostA);
pump();
assert.deepEqual(log, ['A']);

log.length = 0;
await load(await build('B'), canvas(hostB), hostB);
pump();
assert.ok(log.includes('A'), 'a loop in another mount was retired');
assert.ok(log.includes('B'), 'the second mount did not start');

log.length = 0;
await load(await build('C'), canvas(hostA), hostA);
pump();
assert.ok(!log.includes('A'), 'the replaced mount kept its old loop');
assert.ok(log.includes('B'), 'replacing mount A retired mount B');
assert.ok(log.includes('C'), 'the replacement loop did not start');

console.log('PASS: explicit owners keep independent mounts from retiring each other');
