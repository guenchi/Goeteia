// Dead-code elimination keeps a top-level function alive when a lexical
// binder anywhere in the program has the same name.  References are
// collected by symbol, and a let's binding pair supplies the symbol as
// readily as a call does.  Measured on the shared fixture: foo is
// absent from the emitted module's name section when nothing mentions
// it and present once (let ((foo 5)) 1) appears, though nothing calls
// it in either program.
//
// On its own this costs code size and nothing else.  It is the first
// half of what test/defect-spec-candidate-by-name.mjs pins: a function
// that should have been pruned reaches the specialisation pass, where
// the same binding pair is then read as a call.  The two halves are
// held in two cells because a fix for either leaves the other in place.
//
// The twins prove the probe can see foo at all and pin what a fix
// must keep: when foo IS called, or is taken as a value, it must be
// present, or an absence in the first test would be the instrument's
// and not the compiler's -- and a fix that stops counting binders
// must not stop counting value uses.  Its
// foo is self-recursive because a small function called once is
// inlined and vanishes for a reason that has nothing to do with
// dead-code elimination -- measured: the straight-line twin was
// absent too, and read as the probe being blind.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readModule } from './lib/wasm-walk.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

function namesOf(source) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-dce-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, source);
    execFileSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { stdio: 'ignore' });
    const names = [...readModule(fs.readFileSync(wasm)).names.values()];
    fs.rmSync(dir, { recursive: true, force: true });
    return names;
}

test('a lexical binder sharing a name does not keep an uncalled top-level function alive', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    const names = namesOf(fs.readFileSync(path.join(root, 'test/defect-spec-candidate-by-name-fixture.ss'), 'utf8'));
    assert.ok(names.length > 0, 'the module has no name section; the probe read nothing');
    assert.ok(!names.includes('foo'), `foo survived dead-code elimination with no call to it; names: ${names.join(' ')}`);
});

test('twin: a top-level function used only as a value is present in the name section', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    const names = namesOf('(import (rnrs))\n(define (foo a b) (if (fl<? a b) (foo b a) (fl+ a b)))\n(display (vector-length (vector foo)))\n');
    assert.ok(names.includes('foo'), `foo is taken as a value and still absent: a fix that stops counting binders must not stop counting value uses; names: ${names.join(' ')}`);
});

test('twin: a top-level function that is called is present in the name section', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    const names = namesOf('(import (rnrs))\n(define (foo a b) (if (fl<? a b) (foo b a) (fl+ a b)))\n(display (foo 1.0 2.0))\n');
    assert.ok(names.includes('foo'), `foo is called and still absent, so the probe cannot see it; names: ${names.join(' ')}`);
});
