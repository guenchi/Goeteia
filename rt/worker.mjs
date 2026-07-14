// Worker-side loader: the whole render loop off the main thread.
// The main thread transfers an OffscreenCanvas and forwards input
// events as messages (rt/web.mjs's loadGoeteiaWorker is the other
// half); here a small shim wears the canvas API the GL stack
// touches -- width/height, getContext, addEventListener -- and
// re-dispatches forwarded events to whatever listeners the Scheme
// side registered.  The program finds its canvas at
// (js-get (js-global) "__goeteia_canvas") -- there is no document
// in a worker.  requestAnimationFrame works here (the frames pace
// with the display), so fx-loop! runs unchanged.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import { loadGoeteia } from './web.mjs';

const canvasListeners = {};
const globalListeners = {};

// the Scheme side registers key handlers on the global; intercept
// everything that is not the worker's own message plumbing
const realAdd = globalThis.addEventListener.bind(globalThis);
globalThis.addEventListener = (k, f, o) => {
    if (k === 'message' || k === 'messageerror' || k === 'error')
        return realAdd(k, f, o);
    (globalListeners[k] = globalListeners[k] || []).push(f);
};

onmessage = async (e) => {
    const d = e.data;
    if (d.canvas) {
        const off = d.canvas;
        globalThis.__goeteia_canvas = {
            get width() { return off.width; },
            set width(v) { off.width = v; },
            get height() { return off.height; },
            set height(v) { off.height = v; },
            getContext: (k, o) => off.getContext(k, o),
            addEventListener: (k, f) =>
                (canvasListeners[k] = canvasListeners[k] || []).push(f),
        };
        await loadGoeteia(d.wasm);
        postMessage({ ready: true });
    } else if (d.event) {
        const ev = Object.assign({ preventDefault() {} }, d);
        (canvasListeners[d.event] || []).forEach(f => f(ev));
        (globalListeners[d.event] || []).forEach(f => f(ev));
    }
};
