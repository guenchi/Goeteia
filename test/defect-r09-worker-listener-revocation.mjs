// RED ON PURPOSE: the worker shim intercepts addEventListener and
// leaves removeEventListener alone, so nothing can ever be
// unregistered.
//
// rt/worker.mjs replaces globalThis.addEventListener with one that
// pushes the handler into its own table, because forwarded events are
// re-dispatched from that table rather than by the platform.  The word
// removeEventListener does not appear in the file.  A caller that
// removes a listener reaches the native function, which knows nothing
// about the table, and the handler keeps being called.
//
// The canvas shim is the same story one level down: it offers
// addEventListener and no way to undo it, so a library that attaches a
// pointer handler and later disposes has no way to detach -- and, on
// the canvas, no method to call at all.
//
// An event handler that cannot be removed is not only a leak.  It
// is a handler belonging to a torn-down scene still running on every
// keystroke, with whatever it closes over still live and still acting.
//
// Loading this module in plain node is enough, and that is worth
// saying: the defect is in the shim's own bookkeeping, not in anything
// a Worker provides.  The module is imported with the two globals it
// touches replaced by recorders, so which path a call took is a
// reading rather than an inference.
//
// The controls are what must keep working: a registered handler is
// called, the message plumbing still reaches the native
// addEventListener, and a handler removed before any dispatch is the
// only thing that changes.
import test from 'node:test';
import assert from 'node:assert/strict';

const native = [];
globalThis.addEventListener = (k) => native.push(['add', k]);
globalThis.removeEventListener = (k) => native.push(['remove', k]);
globalThis.onmessage = null;
globalThis.postMessage = () => {};

await import('../rt/worker.mjs');

function dispatch(type) {
    globalThis.onmessage({ data: { event: type } });
}

test('CONTROL a registered handler is called', () => {
    let n = 0;
    globalThis.addEventListener('keydown', () => n++);
    dispatch('keydown');
    assert.equal(n, 1);
});

test('CONTROL the message plumbing still reaches the native listener', () => {
    // Without this, "everything goes into the table" would look the
    // same as "the shim is installed correctly".
    const before = native.length;
    globalThis.addEventListener('message', () => {});
    assert.deepEqual(native.slice(before), [['add', 'message']]);
});

test('a removed handler stops being called', () => {
    let n = 0;
    const h = () => n++;
    globalThis.addEventListener('keyup', h);
    globalThis.removeEventListener('keyup', h);
    dispatch('keyup');
    assert.equal(n, 0,
                 'the removal went to the native listener, which knows nothing ' +
                 'about the shim\'s table');
});

test('the canvas shim offers a way to remove a listener at all', () => {
    // The canvas is built when the worker is handed one; ask the shim
    // for the API rather than for a behaviour, because there is no
    // method to call.
    globalThis.onmessage({ data: { canvas: {
        get width() { return 1; }, set width(v) {},
        get height() { return 1; }, set height(v) {},
        getContext: () => ({}),
    }, wasm: null } });
    const c = globalThis.__goeteia_canvas;
    assert.equal(typeof c.addEventListener, 'function');
    assert.equal(typeof c.removeEventListener, 'function',
                 'the canvas shim has no removeEventListener at all');
});
