// What spec-scan must do with the three binding forms that reach it --
// let (plain and named), lambda (proper or dotted formals) and guard --
// one generated fixture per row, read through the --specs mode of
// test/lib/c02-products.sc.  The census in that instrument's --heads
// mode is why these three: every other binding form the prelude
// writes is lowered to them before the pass.
//
// The function under test is self-recursive so the inliner leaves its
// calls in place, and it is named zq because the prelude uses the
// symbols f and g itself, and until the walk carries a bound set a
// prelude-internal use of a name marks the program's function of that
// name escaped (test/defect-spec-prelude-binder-collides-with-user-name).
//
// Readings on bff01a3 before the fix, pinned in a detached worktree:
//
//     binder rows      named-let name ()   (x zq) ()   (zq x) (#f #t)   guard var (#f #t)   dotted (#t #t)
//     traversal rows   all (#f #t)
//     escape rows      all ()
//     5.0 twin         (#t #t)
//     bound rows       value use ()   call ()
//
// So the binder rows (except the dotted one), the 5.0 twin and the
// bound rows are red before the fix; the traversal and escape rows are
// the green twins that a fix which skips inits, bodies or clauses, or
// loses the escape marking, would turn red.
//
// Two macro rows were added against the first fix (compiler.ss
// 60ccdeaf), which compared bound names unmarked: on bff01a3 the hole
// row reads (#f #t) and the own-use row reads no entry (the template's
// use escaped the program's function -- a by-symbol confusion older
// than the fix); on 60ccdeaf both read (#t #t), the hole's call having
// been taken for a call to the local.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

const REC = '(define (zq a b) (if (fl<? a 1.0) b (zq (fl- a 1.0) (fl+ b 2.0))))';
const CALL = '(display (zq 5.0 0.0))';

function specOf(name, forms) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-scan-'));
    const ss = path.join(dir, 'p.ss');
    fs.writeFileSync(ss, '(import (rnrs))\n' + forms.join('\n') + '\n');
    const out = execFileSync(chez, ['--script', path.join(root, 'test/lib/c02-products.sc'), root, ss, '--specs', name], { encoding: 'utf8' });
    fs.rmSync(dir, { recursive: true, force: true });
    const line = out.split('\n').find(l => l.startsWith('(fn-specs'));
    assert.ok(line, `no fn-specs line in:\n${out}`);
    const m = line.match(/\((\S+) ((?:#[tf] ?)+)\)/);
    return m ? m[2].trim() : 'no entry';
}

const rows = [
    // a binder is neither a call nor an escape
    ['named-let name is a binder',        [REC, CALL, '(display (let zq ((x 0)) 1))'],               '#t #t'],
    ['lambda formal in second position',  [REC, CALL, '(display ((lambda (x zq) 1) 1 2))'],           '#t #t'],
    ['lambda formal in first position',   [REC, CALL, '(display ((lambda (zq x) 1) 1 2))'],           '#t #t'],
    ['lambda dotted rest formal',         [REC, CALL, '(display ((lambda (x . zq) 1) 1 2))'],         '#t #t'],
    ['guard variable is a binder',        [REC, CALL, '(display (guard (zq (else 1)) 1))'],           '#t #t'],
    // a real call is still seen wherever it sits
    ['call in a plain-let init',          [REC, '(display (let ((y (zq 5 0.0))) y))'],                '#f #t'],
    ['call in a named-let init',          [REC, '(display (let lp ((y (zq 5 0.0))) y))'],             '#f #t'],
    ['call in a plain-let body',          [REC, '(display (let ((y 1)) (zq 5 0.0)))'],                '#f #t'],
    ['call in a named-let body',          [REC, '(display (let lp ((y 1)) (zq 5 0.0)))'],             '#f #t'],
    ['call in a lambda body',             [REC, '(display ((lambda (y) (zq 5 0.0)) 1))'],             '#f #t'],
    ['call in a guard clause',            [REC, '(display (guard (e ((zq 5 0.0) 1)) (raise (quote x))))'], '#f #t'],
    ['call in a guard body',              [REC, '(display (guard (e (else 1)) (zq 5 0.0)))'],         '#f #t'],
    // a value use still escapes wherever it sits
    ['escape at top level',               [REC, CALL, '(display (vector-length (vector zq)))'],                        'no entry'],
    ['escape in a let body',              [REC, CALL, '(display (let ((y 1)) (vector-length (vector zq))))'],           'no entry'],
    ['escape in a lambda body',           [REC, CALL, '(display ((lambda (y) (vector-length (vector zq))) 1))'],        'no entry'],
    ['escape in a guard body',            [REC, CALL, '(display (guard (e (else 1)) (vector-length (vector zq))))'],    'no entry'],
    // a binder whose initialiser is a flonum is still not a call
    ['flonum binder of an uncalled function', ['(define (foo a b) (fl+ a b))', '(display (let ((foo 5.0)) 1))'], 'no entry'],
    // inside the binder's scope the name is the local, not the candidate
    ['value use of the bound name is not an escape', [REC, CALL, '(display (let ((zq 1)) zq))'],                      '#t #t'],
    ['call of the bound name is not a call',         [REC, CALL, '(display (let ((zq (lambda (x y) x))) (zq 1 2)))'], '#t #t'],
    // a binder a macro introduces is a different binding from the one
    // the program wrote, so the program's call in the template's hole
    // is still a call to the top-level function (it must demote), and
    // the template's own use of its binder is not an escape of it.
    // Bound names must be compared as written, marks and all -- an
    // unmarked comparison reads the hole's call as local and drops it.
    ['a macro-introduced binder does not hide the program\'s call',
        [REC, CALL, '(define-syntax with-zq (syntax-rules () ((_ e) (let ((zq 1)) e))))', '(display (with-zq (zq 5 0.0)))'], '#f #t'],
    ['a macro-introduced binder\'s own use is not an escape',
        [REC, CALL, '(define-syntax with-zq (syntax-rules () ((_ e) (let ((zq 1)) (+ zq e))))', '(display (with-zq (zq 5 0.0)))'], '#f #t'],
];

for (const [title, forms, expected] of rows) {
    test(title, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; the fn-specs instrument is Chez-hosted and this reading was NOT taken)'); return; }
        const name = forms[0].startsWith('(define (foo') ? 'foo' : 'zq';
        assert.equal(specOf(name, forms), expected);
    });
}
