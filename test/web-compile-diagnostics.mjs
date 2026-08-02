import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';
import { compileGoeteia } from '../rt/web.mjs';

test('compileGoeteia preserves compiler diagnostics', async t => {
    const compiler = fs.readFileSync(
        new URL('../goeteia.wasm', import.meta.url));
    const bytes = compiler.buffer.slice(
        compiler.byteOffset, compiler.byteOffset + compiler.byteLength);
    const previousFetch = globalThis.fetch;
    globalThis.fetch = async () => ({ arrayBuffer: async () => bytes });
    t.after(() => { globalThis.fetch = previousFetch; });

    await assert.rejects(
        compileGoeteia('(this-is-unbound)'),
        error => {
            assert.match(error.message, /cannot call.*this-is-unbound/);
            assert.equal(error.output, error.message);
            assert.equal(error.cause?.message, 'unreachable');
            return true;
        });
});
