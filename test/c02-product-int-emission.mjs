// Product greens for the binding-identity design (§5.2): integer
// specialisation, test position, and direct pair access, read from the
// wasm structurally through test/lib/wasm-walk.mjs.
//
// Each number below is an exact known answer on the clean tree, and each
// of the first two was seen to move under a real mutation before the
// cell was trusted:
//   mix   with i32-expr? made false, a nested bitwise intermediate is
//         boxed and unboxed two more times: ref.i31 4 -> 6, i31.get 10 -> 12.
//   gate  with compile-test's (= <) arm removed, the comparison in test
//         position goes through the generic primitive: call 3 -> 4,
//         ref.i31 3 -> 5.
//   bump  uses generic +, which is not on the i32 path, and did not move
//         under either mutation -- the control that each effect is local.
//   second's direct pair reads have no degrading mutant this file knows
//         of: taking car/cdr off the primitive arm makes the compiler
//         refuse the program rather than emit a slower one.  Its row
//         pins the structure and says so.
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

test('mix keeps its nested bitwise intermediate raw', () => {
    const r = m.inspect('mix'); assert.ok(r && r.clean, 'mix missing');
    assert.equal(r.count(REF_I31), 4, `mix tags ${r.count(REF_I31)} times`);
    assert.equal(r.count(I31_GET), 10, `mix untags ${r.count(I31_GET)} times`);
});

test('gate compares in test position without the generic primitive', () => {
    const r = m.inspect('gate'); assert.ok(r && r.clean, 'gate missing');
    assert.equal(r.count(OP.call), 3, `gate makes ${r.count(OP.call)} calls`);
    assert.equal(r.count(REF_I31), 3, `gate tags ${r.count(REF_I31)} times`);
});

test('bump, on the generic path, is what it was (control)', () => {
    const r = m.inspect('bump'); assert.ok(r && r.clean, 'bump missing');
    assert.equal(r.count(REF_I31), 6);
    assert.equal(r.count(OP.call), 5);
});

test('second reads both pair fields directly (structure only; no degrading mutant known)', () => {
    const r = m.inspect('second'); assert.ok(r && r.clean, 'second missing');
    assert.equal(r.count(OP['struct.get']), 2, `second reads ${r.count(OP['struct.get'])} fields`);
});
