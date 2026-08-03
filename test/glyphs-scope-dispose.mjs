import assert from 'node:assert/strict';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { compileSource } from '../rt/compile.mjs';
import { callMain, makeJsBridge } from '../rt/jsbridge.mjs';

const io = {
    write_byte: () => {}, read_byte: () => -1,
    path_byte: () => {}, open_read: () => -1, open_write: () => -1,
    fread: () => -1, fwrite: () => {}, fclose: () => {},
};

async function run(bytes, owner) {
    globalThis.__owner = owner;
    let exportsRef = null;
    const { instance } = await WebAssembly.instantiate(bytes, {
        io, js: makeJsBridge(() => exportsRef),
    });
    exportsRef = instance.exports;
    await callMain(instance.exports);
}

test('glyph tracking is owner-scoped and exposes a disposer', async t => {
    const active = new Map();
    const frames = [];
    const saved = new Map();
    for (const key of ['addEventListener', 'removeEventListener',
                       'requestAnimationFrame', '__owner']) {
        saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    }
    t.after(() => {
        for (const [key, descriptor] of saved) {
            if (descriptor) Object.defineProperty(globalThis, key, descriptor);
            else delete globalThis[key];
        }
    });
    globalThis.addEventListener = (event, handler) => {
        if (!active.has(event)) active.set(event, new Set());
        active.get(event).add(handler);
    };
    globalThis.removeEventListener = (event, handler) => {
        active.get(event)?.delete(handler);
    };
    globalThis.requestAnimationFrame = callback => {
        frames.push(callback);
        return frames.length;
    };

    const bytes = await compileSource(
        '(import (web js) (web glyphs))\n' +
        '(glyphs-dodge! \'() (js-get (js-global) "__owner"))',
        { baseDir: fileURLToPath(new URL('..', import.meta.url)) });
    const ownerA = {};
    const ownerB = {};
    await run(bytes, ownerA);
    await run(bytes, ownerB);

    for (const event of ['pointermove', 'scroll', 'resize'])
        assert.equal(active.get(event)?.size, 2, `${event} must coexist`);
    assert.equal(frames.length, 2);

    ownerA.goeteiaGlyphsListenerCleanup();
    for (const event of ['pointermove', 'scroll', 'resize'])
        assert.equal(active.get(event)?.size, 1, `${event} was not disposed`);

    const tickA = frames.shift();
    const tickB = frames.shift();
    tickA(0);
    tickB(0);
    assert.equal(frames.length, 1, 'only the live owner should reschedule');
});
