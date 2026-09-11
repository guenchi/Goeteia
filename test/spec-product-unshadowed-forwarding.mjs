// A product cell for the spec-shadowed-parameter fix (2026-09-11): the
// demotion subtracts a call's lexically-shadowed locals from the f64
// name set, and a first version of that subtraction removed the
// enclosing function's parameters at EVERY call -- shadow or not,
// because spec-scan seeds the bound set WITH those parameters -- and so
// deleted ordinary parameter forwarding.  Nothing in the suite or the
// four c02-product cells caught it: every call in them passes a flonum
// EXPRESSION, which fl-expr-in? classifies by its head without ever
// consulting the name set, so the whole name-set path was untested.
//
// This is that missing twin.  zq forwards both parameters with NO
// shadowing anywhere -- a bare, b inside an fl+ -- so both must stay
// f64.  A regression that over-subtracts turns (zq #t #t) into
// (zq #f #t) or (zq #f #f); the printed value stays 5.0 throughout,
// which is exactly why this reads the product and not the output.  The
// instrument is Chez-hosted, like the other product cells.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

test('an unshadowed recursive function keeps both f64 parameters', () => {
    if (!chez) {
        console.log('NOT EXERCISED HERE (no chez on PATH; the fn-specs product instrument is Chez-hosted and this reading was NOT taken)');
        return;
    }
    const out = execFileSync(chez, ['--script', path.join(root, 'test/lib/c02-products.sc'), root,
                                    path.join(root, 'test/spec-unshadowed-forwarding-fixture.ss'),
                                    '--specs', 'zq'], { encoding: 'utf8' });
    const line = out.split('\n').find(l => l.startsWith('(fn-specs'));
    assert.ok(line, `no fn-specs line in:\n${out}`);
    assert.match(line, /\(zq #t #t\)/, `unshadowed forwarding lost a parameter:\n${line}`);
});
