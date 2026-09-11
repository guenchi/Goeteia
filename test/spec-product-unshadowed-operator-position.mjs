// The positive twin for the operator-position fix (2026-09-11): a fix
// for defect-spec-shadowed-primitive-in-operator-position that declines
// EVERY primitive head -- not only the lexically bound ones -- would
// pass every value cell, because declining a head only costs an f64
// slot, never a value.  So the red cell alone cannot tell a correct fix
// from one that specialises nothing; only a reading of the product can.
//
// Here fl+ in operator position is unshadowed, the primitive, and both
// recursive arguments are flonum expressions, so both parameters stay
// f64: (zq #t #t).  An over-declining fix reads () instead.  Proven red
// under exactly that mutation (the head check forced to decline every
// primitive) before this was trusted.  The instrument is Chez-hosted,
// like the other product cells.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

test('an unshadowed primitive head in operator position keeps both f64 parameters', () => {
    if (!chez) {
        console.log('NOT EXERCISED HERE (no chez on PATH; the fn-specs product instrument is Chez-hosted and this reading was NOT taken)');
        return;
    }
    const out = execFileSync(chez, ['--script', path.join(root, 'test/lib/c02-products.sc'), root,
                                    path.join(root, 'test/spec-unshadowed-operator-position-fixture.ss'),
                                    '--specs', 'zq'], { encoding: 'utf8' });
    const line = out.split('\n').find(l => l.startsWith('(fn-specs'));
    assert.ok(line, `no fn-specs line in:\n${out}`);
    assert.match(line, /\(zq #t #t\)/, `an unshadowed operator-position head lost a parameter:\n${line}`);
});
