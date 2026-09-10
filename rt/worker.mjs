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

import { loadGoeteia } from './web.mjs';

const canvasListeners = {};
const globalListeners = {};

// the Scheme side registers key handlers on the global; intercept
// everything that is not the worker's own message plumbing
const realAdd = globalThis.addEventListener.bind(globalThis);
const realRemove = globalThis.removeEventListener.bind(globalThis);

// The worker's own plumbing keeps the real listeners; everything else
// is held in a table here, because a forwarded event is a message and
// not an event the platform will dispatch.
function isPlumbing(k) {
    return k === 'message' || k === 'messageerror' || k === 'error';
}

// Registration is intercepted, so removal has to be intercepted too.
// It was not: a handler added here went into the table, and the
// matching removeEventListener went to the platform, which has no
// entry for it and no way to say so.  The handler stayed in the table
// and kept being called -- a listener that cannot be taken off is a
// leak with a behaviour, since the object it closes over stays
// reachable and keeps answering events meant for whatever replaced it.
function drop(table, k, f) {
    const l = table[k];
    if (!l) return;
    const i = l.indexOf(f);
    if (i >= 0) l.splice(i, 1);
}

globalThis.addEventListener = (k, f, o) => {
    if (isPlumbing(k)) return realAdd(k, f, o);
    (globalListeners[k] = globalListeners[k] || []).push(f);
};

globalThis.removeEventListener = (k, f, o) => {
    if (isPlumbing(k)) return realRemove(k, f, o);
    drop(globalListeners, k, f);
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
            removeEventListener: (k, f) => drop(canvasListeners, k, f),
        };
        await loadGoeteia(d.wasm);
        postMessage({ ready: true });
    } else if (d.event) {
        const ev = Object.assign({ preventDefault() {} }, d);
        (canvasListeners[d.event] || []).forEach(f => f(ev));
        (globalListeners[d.event] || []).forEach(f => f(ev));
    }
};
