// What dead-code elimination must do with the binding forms, one
// generated fixture per row, read from the emitted module's name
// section.  form-refs collects references by symbol; a binder name is
// not a reference, and everything else -- inits, bodies, a reference
// to a name that also happens to be bound around it -- still is.  The
// over-approximation rows are deliberate: form-refs tracks no scope,
// so a body reference to a lexically bound `foo` keeps the top-level
// foo alive, and a fix that adds scope tracking to remove that would
// be a different change with different risks.
//
// R = (vector-length (vector foo)) is the reference: a value use, so
// the inliner cannot remove foo before dead-code elimination is asked
// about it.  "absent" rows mention foo only as a binder.
//
// Readings on 35ea5da, before the fix, taken in a detached worktree
// of that commit: every "absent" row present (10 red), every
// "present" row present (10 green).  The first reading of this file
// was taken on the shared tree while the fix was already in progress
// there, and read 8 of the 10 as absent -- the fix working, not the
// baseline -- which is why the baseline is stated with its commit.
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

const DEF = '(define (foo a b) (if (fl<? a b) (foo b a) (fl+ a b)))';
const R = '(vector-length (vector foo))';

function hasFoo(forms) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-dcef-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, '(import (rnrs))\n' + [DEF, ...forms].join('\n') + '\n');
    execFileSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { stdio: 'ignore' });
    const names = [...readModule(fs.readFileSync(wasm)).names.values()];
    fs.rmSync(dir, { recursive: true, force: true });
    assert.ok(names.length > 0, 'no name section; the probe read nothing');
    return names.includes('foo') ? 'present' : 'absent';
}

const rows = [
    // binders are not references
    ['plain let binder',                    ['(display (let ((foo 5)) 1))'],                                        'absent'],
    ['named let name',                      ['(display (let foo ((x 5)) 1))'],                                      'absent'],
    ['named let binder',                    ['(display (let again ((foo 5)) 1))'],                                  'absent'],
    ['loop name (a named let loop-ok? takes)',   ['(display (let foo ((x 5)) (if (< x 1) 1 (foo (- x 1)))))'],      'absent'],
    ['loop binder (a named let loop-ok? takes)', ['(display (let again ((foo 5)) (if (< foo 1) 1 (again (- foo 1)))))'], 'absent'],
    ['lambda formal',                       ['(display ((lambda (foo) 1) 5))'],                                     'absent'],
    ['lambda first of dotted formals',      ['(display ((lambda (foo . rest) 1) 5))'],                              'absent'],
    ['lambda dotted rest formal',           ['(display ((lambda (x . foo) 1) 5))'],                                 'absent'],
    ['lambda bare rest formal',             ['(display ((lambda foo 1) 5))'],                                       'absent'],
    // every other position is still walked
    ['reference in a plain let init',       [`(display (let ((x ${R})) 1))`],                                        'present'],
    ['reference in a plain let body',       [`(display (let ((x 5)) ${R}))`],                                        'present'],
    ['reference in a named let init',       [`(display (let again ((x ${R})) 1))`],                                  'present'],
    ['reference in a named let body',       [`(display (let again ((x 5)) ${R}))`],                                  'present'],
    ['reference in a loop init',            [`(display (let again ((x ${R})) (if (< x 1) 1 (again (- x 1)))))`],     'present'],
    ['reference in a loop body',            [`(display (let again ((x 5)) (if (< x 1) ${R} (again (- x 1)))))`],     'present'],
    ['reference in a lambda body',          [`(display ((lambda () ${R})))`],                                        'present'],
    // no scope tracking: a reference under a same-named binder still counts
    ['reference under a let binder of the same name',    [`(display (let ((foo 5)) ${R}))`],                         'present'],
    ['reference under a lambda formal of the same name', [`(display ((lambda (foo) ${R}) 5))`],                      'present'],
    // hygiene: a macro's binder is not the program's reference, and vice versa
    ['macro binder with the reference in the hole',  ['(define-syntax with-foo (syntax-rules () ((_ e) (let ((foo 5)) e))))', `(display (with-foo ${R}))`], 'present'],
    ['macro binder with nothing in the hole',        ['(define-syntax with-foo (syntax-rules () ((_ e) (let ((foo 5)) e))))', '(display (with-foo 1))'],     'absent'],
];

for (const [title, forms, expected] of rows) {
    test(title, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
        assert.equal(hasFoo(forms), expected);
    });
}
