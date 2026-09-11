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
        // the clause keeps this row about compileGoeteia PRESERVING a
        // diagnostic rather than about which diagnostic a clause-less
        // program gets
        compileGoeteia('(import (rnrs))\n(this-is-unbound)'),
        error => {
            // The reference check reaches it before code generation
            // does now, so the wording is "unbound variable" rather
            // than "cannot call" -- an earlier and better diagnostic.
            // What this row holds is that compileGoeteia PRESERVES
            // whichever one the compiler gave, not which one it is.
            assert.match(error.message, /unbound variable.*this-is-unbound/);
            assert.equal(error.output, error.message);
            assert.equal(error.cause?.message, 'unreachable');
            return true;
        });
});
