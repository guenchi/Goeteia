import assert from 'node:assert/strict';
import { compileSource } from '../rt/compile.mjs';
import { loadGoeteia, loadGoeteiaAuto } from '../rt/web.mjs';

const moduleText = String(await compileSource(
    '(display (%mem-u8-ref 0))\n(%mem-u8-set! 0 99)\n',
    { script: true, target: 'js' }));
const oldLocation = Object.getOwnPropertyDescriptor(globalThis, 'location');
const oldFetch = Object.getOwnPropertyDescriptor(globalThis, 'fetch');
let fetches = 0;

try {
    Object.defineProperty(globalThis, 'location', {
        configurable: true,
        value: {
            href: 'https://example.test/index.html?goeteia=js',
            search: '?goeteia=js',
        },
    });
    Object.defineProperty(globalThis, 'fetch', {
        configurable: true,
        value: async url => {
            fetches++;
            assert.equal(url, 'https://example.test/program.mjs');
            return { ok: true, text: async () => moduleText };
        },
    });

    loadGoeteia._out.length = 0;
    await loadGoeteiaAuto('program.wasm', 'program.mjs');
    await loadGoeteiaAuto('program.wasm', 'program.mjs');

    assert.equal(Buffer.from(loadGoeteia._out).toString(), '00');
    assert.equal(fetches, 2);
} finally {
    if (oldLocation) Object.defineProperty(globalThis, 'location', oldLocation);
    else delete globalThis.location;
    if (oldFetch) Object.defineProperty(globalThis, 'fetch', oldFetch);
    else delete globalThis.fetch;
}
