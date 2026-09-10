// The same fault as test/defect-spec-candidate-by-name.mjs, reached
// from ordinary code: a program does not have to write a let binding
// of its own function's name, because the prelude already has one.
// src/prelude.ss binds (g (gcd n d)) inside a let, and spec-scan --
// a flat walk with no knowledge of binding forms -- records that pair
// as a call to whatever top-level function is named g.  A user's
// self-recursive g, called with flonums everywhere, therefore
// collects a one-argument fake call from inside the prelude and loses
// its specialisation entirely:
//
//     (define (g a b) ...) recursive, called (g 5.0 0.0)       no entry
//     the same function named gzz                             (gzz #t #t)
//
// Both programs answer 10.0; the demoting direction is the safe one,
// so this is a pessimisation and not a wrong answer.  It is still a
// defect: what the specialiser does to a function depends on whether
// its name happens to be bound somewhere in the prelude, and the
// program has no way to know that.  Why the fake call clears the entry
// outright rather than demoting one parameter is not measured here;
// the assertion is that g's entry is gzz's entry, whichever mechanism
// a fix removes.
//
// The function is self-recursive because a small function called once
// is inlined before the pass and has no entry for a reason unrelated
// to this one; the control is the proof that the shape is specialised
// at all.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

function specOf(name) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-spec-'));
    const ss = path.join(dir, 'p.ss');
    fs.writeFileSync(ss, `(import (rnrs))\n(define (${name} a b) (if (fl<? a 1.0) b (${name} (fl- a 1.0) (fl+ b 2.0))))\n(display (${name} 5.0 0.0))\n`);
    const out = execFileSync(chez, ['--script', path.join(root, 'test/lib/c02-products.sc'), root, ss, '--specs', name], { encoding: 'utf8' });
    fs.rmSync(dir, { recursive: true, force: true });
    const line = out.split('\n').find(l => l.startsWith('(fn-specs'));
    assert.ok(line, `no fn-specs line in:\n${out}`);
    const m = line.match(/\((\S+) ((?:#[tf] ?)+)\)/);
    return m ? m[2].trim() : null;
}

test('control: a self-recursive two-flonum function is specialised on both parameters', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; the fn-specs instrument is Chez-hosted and this reading was NOT taken)'); return; }
    assert.equal(specOf('gzz'), '#t #t');
});

test('a function named g is specialised the same as one named gzz', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; the fn-specs instrument is Chez-hosted and this reading was NOT taken)'); return; }
    assert.equal(specOf('g'), specOf('gzz'), 'the prelude binds (g ...) in a let, and the walk read that pair as a call to the user\'s g');
});
