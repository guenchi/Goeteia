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

test('a new glyphs run retires the previous animation loop', async t => {
    const frames = [];
    const saved = new Map();
    for (const key of ['addEventListener', 'removeEventListener',
                       'requestAnimationFrame', 'goeteiaGlyphsGeneration']) {
        saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    }
    t.after(() => {
        for (const [key, descriptor] of saved) {
            if (descriptor) Object.defineProperty(globalThis, key, descriptor);
            else delete globalThis[key];
        }
    });
    globalThis.addEventListener = () => {};
    globalThis.removeEventListener = () => {};
    globalThis.requestAnimationFrame = callback => {
        frames.push(callback);
        return frames.length;
    };

    const bytes = await compileSource(
        "(import (web glyphs))\n(glyphs-dodge! '())",
        { baseDir: fileURLToPath(new URL('..', import.meta.url)) });
    await run(bytes);
    await run(bytes);

    assert.equal(frames.length, 2);
    const oldTick = frames.shift();
    oldTick(0);
    assert.equal(frames.length, 1,
                 'the superseded loop must not schedule another frame');
});
