// Browser loader for compiled Goeteia modules, main thread: full DOM
// access through the js bridge.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import { makeJsBridge, callMain } from './jsbridge.mjs';

export async function loadGoeteia(url) {
    let exportsRef = null;
    const { instance } = await WebAssembly.instantiate(
        await (await fetch(url)).arrayBuffer(),
        {
            io: {
                write_byte: b => loadGoeteia._out.push(b),
                read_byte: () => -1,
                path_byte: () => {}, open_read: () => -1, open_write: () => -1,
                fread: () => -1, fwrite: () => {}, fclose: () => {},
            },
            js: makeJsBridge(() => exportsRef),
        });
    exportsRef = instance.exports;
    // expose the staging memory so Scheme can build typed-array views
    if (instance.exports.memory) globalThis.__goeteia_mem = instance.exports.memory;
    await callMain(instance.exports);
    return instance.exports;
}
loadGoeteia._out = [];

// Run a module in a Worker over an OffscreenCanvas: the render loop
// leaves the main thread entirely (a busy main thread no longer
// drops frames).  Input forwards as messages -- keys from the
// window, pointer events from the canvas -- and rt/worker.mjs
// re-dispatches them to the module's listeners.  The module finds
// its canvas at (js-get (js-global) "__goeteia_canvas").
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
