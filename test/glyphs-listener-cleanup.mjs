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

async function run(bytes) {
    let exportsRef = null;
    const { instance } = await WebAssembly.instantiate(bytes, {
        io, js: makeJsBridge(() => exportsRef),
    });
    exportsRef = instance.exports;
    await callMain(instance.exports);
}

test('a new glyphs run removes listeners from the previous run', async t => {
    const active = new Map();
    let removals = 0;
    const saved = new Map();
    for (const key of ['addEventListener', 'removeEventListener',
                       'requestAnimationFrame',
                       'goeteiaGlyphsListenerCleanup']) {
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
        if (active.get(event)?.delete(handler)) removals++;
    };
    globalThis.requestAnimationFrame = () => 1;

    const bytes = await compileSource(
        "(import (web glyphs))\n(glyphs-dodge! '())",
        { baseDir: fileURLToPath(new URL('..', import.meta.url)) });
    await run(bytes);
    await run(bytes);

    assert.equal(removals, 3);
    for (const event of ['pointermove', 'scroll', 'resize'])
        assert.equal(active.get(event)?.size, 1, `${event} must not stack`);
});
