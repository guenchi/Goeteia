// The wasm target's limit on record types with relatives (ledger R74).
//
// An ancestor's accessor reads a descendant's instance, so on wasm the
// struct type of each field count used by a record type that has a
// parent or a child is declared a subtype of the next smaller such
// count: one chain per module.  The engine allows 63 supertypes, so a
// program whose LIVE record types with a parent or a child have more
// than 63 distinct field counts is refused when it is compiled, with a
// message that names the limit.  The JS target's records are arrays and
// have no such limit.  A type with NO fields is the base struct type
// itself and takes no place in the chain: the condition types the
// prelude defines are such types and are live in nearly every program,
// and they must not cost a program one of its 63.
//
// Each program here defines one line of N types: r1 has one field and
// each next type names the one before it as its parent and adds a field,
// so the field counts of the related types are exactly 1..N.
//   - 63 types: compiles and answers #t on both targets;
//   - 64 types, the last one used: refused on wasm, #t on JS;
//   - 64 types of which the last is never used: its descriptor is dead
//     code, the count is taken over what is left, and wasm answers #t;
//   - 63 types and, beside them, a parent and a child without fields:
//     the count is still 63, and wasm answers #t.
//
// BEFORE THE CHANGE the parent clause was dropped without a word and none
// of these programs compiled (a constructor call with the wrong count).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileSource } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'chain-limit-'));

// n types defined; an instance of the type `used` is made and read.
// With `fieldless`, a parent and a child that have no fields are defined
// and used too.
function program(n, used, fieldless = false) {
    const out = ['(import (rnrs))', '(define-record-type r1 (fields f1))'];
    if (fieldless) {
        out.push('(define-record-type z0)', '(define-record-type z1 (parent z0))');
        out.push('(define z (make-z1))');
    }
    for (let k = 2; k <= n; k++) out.push(`(define-record-type r${k} (parent r${k - 1}) (fields f${k}))`);
    const args = Array.from({ length: used }, (_, i) => `${i + 1}`).join(' ');
    const mid = Math.ceil(used / 2);
    out.push(`(define x (make-r${used} ${args}))`);
    out.push(`(display (and (r1? x) (r${mid}? x) (r${used}? x)${fieldless ? ' (z0? z) (z1? z) (not (z0? x)) (not (r1? z))' : ''}`
        + ` (equal? (list (r1-f1 x) (r${mid}-f${mid} x) (r${used}-f${used} x)) '(1 ${mid} ${used}))))`);
    return out.join('\n') + '\n';
}

async function onWasm(text) {
    let bytes;
    try { bytes = await compileSource(text, { name: 'records-chain-limit' }); }
    catch (e) { return { refused: `${e.output ?? ''}${e.message}` }; }
    return { text: (await runModule(bytes)).text };
}
async function onJs(text, tag) {
    const made = await compileSource(text, { name: 'records-chain-limit', target: 'js' });
    const file = path.join(dir, `${tag}.mjs`);
    fs.writeFileSync(file, made);
    return { text: (await runJsModule(file)).text };
}

test('63 distinct field counts among related types: wasm answers', async () => {
    assert.deepEqual(await onWasm(program(63, 63)), { text: '#t' });
});
test('63 distinct field counts among related types: js answers', async () => {
    assert.deepEqual(await onJs(program(63, 63), 'n63'), { text: '#t' });
});
test('64 distinct field counts among related types: wasm refuses, naming the limit', async () => {
    const r = await onWasm(program(64, 64));
    assert.ok('refused' in r, `compiled and printed ${r.text}; expected a refusal`);
    assert.match(r.refused, /more than 63 distinct field counts/);
    assert.match(r.refused, /63 supertypes/);
    assert.match(r.refused, /\b64\b/);
});
test('64 distinct field counts among related types: js answers', async () => {
    assert.deepEqual(await onJs(program(64, 64), 'n64'), { text: '#t' });
});
test('the count is taken over live types: 64 types, the last never used, wasm answers', async () => {
    assert.deepEqual(await onWasm(program(64, 63)), { text: '#t' });
});
test('types without fields take no place: 63 counts and a fieldless parent and child, wasm answers', async () => {
    assert.deepEqual(await onWasm(program(63, 63, true)), { text: '#t' });
});
test('types without fields take no place: the same on js', async () => {
    assert.deepEqual(await onJs(program(63, 63, true), 'n63z'), { text: '#t' });
});

test.after(() => fs.rmSync(dir, { recursive: true, force: true }));
