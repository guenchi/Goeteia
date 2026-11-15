// Product greens for the binding-identity design (§5.2): integer
// specialisation, test position, and direct pair access, read from the
// wasm structurally through test/lib/wasm-walk.mjs.
//
// Each number below is an exact known answer on the clean tree, and each
// of the first two was seen to move under a real mutation before the
// cell was trusted:
//   mix   with i32-expr? made false, a nested bitwise intermediate is
//         boxed and unboxed two more times: ref.i31 6 -> 8, i31.get 10 -> 12.
//         (Before shifts were checked the clean count was 4 -> 6.  mix
//         shifts right, and since 2026-10-22 a shift that is refused
//         boxes its operand and count to name them in the error; those
//         two ref.i31 sit in the refusal branch, which runs only for a
//         negative count, and count here because this file counts the
//         code, not what runs.  The intermediate on the path taken stays
//         raw: i31.get is unchanged.)
//   gate  with compile-test's (= <) arm removed, the comparison in test
//         position goes through the generic primitive: call 3 -> 4,
//         ref.i31 3 -> 5.
//   bump  uses generic +, which is not on the i32 path, and did not move
//         under either mutation -- the control that each effect is local.
//   second's direct pair reads have no degrading mutant this file knows
//         of: taking car/cdr off the primitive arm makes the compiler
//         refuse the program rather than emit a slower one.  Its row
//         pins the structure and says so.
//
// SINCE BATCH M50 (ledger R76, design (III) with amendments 1-4) a
// bitwise form is an i32 tree only over typed operands -- literals, typed
// slots, byte loads, nested typed operations -- or as a bitwise-and with a
// fixnum literal mask, whose answer is a fixnum whatever its other operand
// is.  mix's x is a parameter, so its nested expression is no longer a
// tree and its intermediate is boxed; the row that showed the raw
// intermediate is now mixb's, which threads the same expression through
// two byte loads.  Measured by main on the branch (11-15) and against a
// mutant whose i32-expr? answers #f:
//   mixb  ref.i31 8, i31.get 16, call 6; the mutant 12, 22, 8.
//   gate  its (bitwise-and x 7) is a masked tree again, so the comparison
//         in test position stays off the generic primitive: call 4,
//         ref.i31 4 (one call and one tag more than before M50: the masked
//         leaf's slow branch; i31.get 11); the mutant 5, 6.
//   mix   ref.i31 8, i31.get 15: its (bitwise-and x 255) is a masked
//         leaf, and the leaf tests the low bit (a character is an i31 too,
//         amendment 4), one i31.get more than the mutant's 8, 14.  Its
//         nested xor is not a tree, so the row pins the structure.
//   bump  ref.i31 7, call 6, the same under the mutant: the control
//         (i31.get 17, the mutant 16, not pinned).
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readModule, OP } from './lib/wasm-walk.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-ie-')), 'fixture.wasm');
execFileSync(path.join(root, 'bin/goeteiac'), [path.join(root, 'test/c02-int-fixture.ss'), out], { stdio: 'ignore' });
const m = readModule(fs.readFileSync(out));
const REF_I31 = 0xfb1c, I31_GET = 0xfb1d;

test('the walker consumes every function body exactly', () => {
    const [clean, total] = m.walkClean();
    assert.equal(clean, total, `walker desynced on ${total - clean} of ${total} bodies`);
});

test('mixb keeps its nested bitwise intermediate raw', () => {
    const r = m.inspect('mixb'); assert.ok(r && r.clean, 'mixb missing');
    assert.equal(r.count(REF_I31), 8, `mixb tags ${r.count(REF_I31)} times`);
    assert.equal(r.count(I31_GET), 16, `mixb untags ${r.count(I31_GET)} times`);
});

test('mix, whose operand is a parameter, is on the generic path (structure only)', () => {
    const r = m.inspect('mix'); assert.ok(r && r.clean, 'mix missing');
    assert.equal(r.count(REF_I31), 8, `mix tags ${r.count(REF_I31)} times`);
    assert.equal(r.count(I31_GET), 15, `mix untags ${r.count(I31_GET)} times`);
});

test('gate compares in test position without the generic primitive', () => {
    const r = m.inspect('gate'); assert.ok(r && r.clean, 'gate missing');
    assert.equal(r.count(OP.call), 4, `gate makes ${r.count(OP.call)} calls`);
    assert.equal(r.count(REF_I31), 4, `gate tags ${r.count(REF_I31)} times`);
});

test('bump, on the generic path, is what it was (control)', () => {
    const r = m.inspect('bump'); assert.ok(r && r.clean, 'bump missing');
    assert.equal(r.count(REF_I31), 7);
    assert.equal(r.count(OP.call), 6);
});

test('second reads both pair fields directly (structure only; no degrading mutant known)', () => {
    const r = m.inspect('second'); assert.ok(r && r.clean, 'second missing');
    assert.equal(r.count(OP['struct.get']), 2, `second reads ${r.count(OP['struct.get'])} fields`);
});
