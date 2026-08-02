// A loop started by one module instance must retire when ANOTHER
// instance calls fx-init! -- the live-page case: switching demos must
// not leave the previous demo's rAF loop running forever, pinning its
// instance and GL context.  A generation counter under __goeteia_*
// cannot do this: the bridge keeps that namespace private per
// instance, so each module would only ever see its own counter.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { makeJsBridge } from '../rt/jsbridge.mjs';

const root = new URL('..', import.meta.url).pathname;
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-fx-gen-'));
const build = (tag) => {
    const src = path.join(dir, `${tag}.ss`);
    const out = path.join(dir, `${tag}.wasm`);
    fs.writeFileSync(src,
        '(import (rnrs) (web js) (gfx fx) (gfx gl))\n' +
        '(fx-init! (js-get (js-global) "__c"))\n' +
        '(fx-ticks! (lambda (el dt)\n' +
        `  (js-method (js-get (js-global) "__log") "push" "${tag}")))\n`);
    execFileSync(path.join(root, 'bin/goeteiac'), [src, out], { cwd: root });
    return out;
};

const log = [];
let rafs = [];
const glStub = new Proxy({}, { get: (_, p) =>
    /^[A-Z0-9_]+$/.test(p) ? 0x8000
    : /Parameter$/.test(p) ? () => 1
    : /^create/.test(p) ? () => ({})
    : /Location$/.test(p) ? () => 0
    : () => undefined });
globalThis.__log = log;
globalThis.__c = { getContext: () => glStub };
globalThis.requestAnimationFrame = (cb) => rafs.push(cb);
const io = { write_byte() {}, read_byte: () => -1, path_byte() {},
             open_read: () => -1, open_write: () => -1,
             fread: () => -1, fwrite() {}, fclose() {} };
async function load(file) {
    let ex;
    const { instance } = await WebAssembly.instantiate(
        fs.readFileSync(file), { io, js: makeJsBridge(() => ex) });
    ex = instance.exports;
    globalThis.__goeteia_mem = ex.memory;
    ex.main();
}
const pump = () => { const cbs = rafs; rafs = []; cbs.forEach(cb => cb(16)); };

try {
    await load(build('A'));
    pump();
    assert.deepEqual(log, ['A'], 'the first instance drives its own loop');

    log.length = 0;
    await load(build('B'));           // a second instance takes the stage
    pump(); pump();
    assert.ok(!log.includes('A'),
        `the first instance's loop outlived its retirement: ${log.join(',')}`);
    assert.ok(log.includes('B'), 'the second instance should be running');
    console.log('PASS: fx-init! retires a loop started by another instance');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
