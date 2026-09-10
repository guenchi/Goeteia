// A product green for float specialisation as EMITTED (design §5.2, row 2):
// intermediates stay raw and boxing happens only at the stated boundary.
//
// The cell reads the wasm structurally through test/lib/wasm-walk.mjs.  A
// count of f64.add/f64.mul is deliberately NOT the assertion: with direct
// emission disabled, norm still contains the same two multiplies and one
// add -- inside boxing -- which is the trap the design names.  What moves
// is the number of boxes norm allocates (1, its return, versus 3) and the
// number of raw f64 locals run keeps (2 versus 1).  Both were seen to
// move before this cell was trusted.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readModule, OP } from './lib/wasm-walk.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-fe-')), 'fixture.wasm');
execFileSync(path.join(root, 'bin/goeteiac'), [path.join(root, 'test/c02-products-fixture.ss'), out], { stdio: 'ignore' });
const m = readModule(fs.readFileSync(out));

test('the walker consumes every function body exactly (its own known answer)', () => {
    const [clean, total] = m.walkClean();
    assert.equal(clean, total, `walker desynced on ${total - clean} of ${total} bodies`);
});

test('norm boxes once, at its return, and not around its intermediates', () => {
    const r = m.inspect('norm');
    assert.ok(r && r.clean, 'norm not found or not walked clean');
    assert.equal(r.count(OP['struct.new']), 1, `norm allocates ${r.count(OP['struct.new'])} boxes`);
    assert.equal(r.count(OP['f64.mul']), 2, 'norm lost a direct multiply');
});

test('run keeps its accumulator in a raw f64 slot', () => {
    const r = m.inspect('run');
    assert.ok(r && r.clean, 'run not found or not walked clean');
    assert.equal(r.f64Locals, 2, `run has ${r.f64Locals} raw f64 locals`);
});
