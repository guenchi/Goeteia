// A lexical binding of a top-level function's name does two things to
// the specialisation pass, neither of which the binding asked for.
// Measured on this fixture, with the --specs mode of the instrument:
//
//     (define (foo a b) (fl+ a b))  (display 1)                  no entry
//     same, plus (display (let ((foo 5)) 1))                      (foo #f #t)
//
// First, dead-code elimination collects references by symbol, and the
// binder's name counts: foo is absent from the module's name section
// without the binder and present with it (the cell beside this one
// pins that half).  Second, spec-scan is a flat walk over the form
// tree with no knowledge of binding forms, so the binding pair
// (foo 5) is recorded as a CALL to foo with 5 as its argument.  The
// rule in compute-fn-specs! that marks a candidate with no visible
// call as escaped -- the rule that protects every function whose real
// call is constructed at emission -- therefore does not fire, and the
// optimistic all-f64 seed is published with parameter 1 demoted by
// the initialiser's type.  That last clause is the prediction that
// separated this mechanism from two earlier stories: (foo 5.0) gives
// (foo #t #t), and 5, 'x and (5 6) all give (foo #f #t).
//
// Harmless while every real call is visible, because a real call
// demotes the seed.  Fatal for the function whose only call is
// constructed at emission, which is how $escape came to trap once a
// lexical $escape existed and why it is on $spec-denylist.  This cell
// pins the general fault; the denylist entry covers the known victim.
// A fix that teaches spec-scan the binding forms turns this green
// while leaving the DCE half to its own cell.
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
