// compute-fn-specs! admits a top-level function as a specialisation
// candidate on a reference to its NAME, and a lexical binder's name
// counts.  A function nothing calls therefore gets the optimistic
// all-f64 seed and, with no call to demote it, is published with f64
// parameters it was never shown to take.  Measured:
//
//     (define (foo a b) (fl+ a b))  (display 1)                  no entry
//     same, plus (display (let ((foo 5)) 1))                      (foo #f #t)
//
// Harmless while every call to such a function is visible to the pass,
// because a visible call demotes the seed.  It is not harmless for a
// function whose only call is constructed at emission time -- which is
// exactly how $escape came to trap once a lexical $escape existed, and
// why $escape is now on $spec-denylist.  This cell pins the general
// fault; the denylist entry covers the one known victim.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

test('a lexical binder sharing a name does not enrol an uncalled top-level function', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; the fn-specs instrument is Chez-hosted and this reading was NOT taken)'); return; }
    const out = execFileSync(chez, ['--script', path.join(root, 'test/lib/c02-products.sc'), root,
                                   path.join(root, 'test/defect-spec-candidate-by-name-fixture.ss'), '--specs', 'foo'],
                             { encoding: 'utf8' });
    const line = out.split('\n').find(l => l.startsWith('(fn-specs'));
    assert.ok(line, `no fn-specs line in:\n${out}`);
    assert.doesNotMatch(line, /\(foo /, `foo was published as a specialisation candidate with no call to it:\n${line}`);
});
