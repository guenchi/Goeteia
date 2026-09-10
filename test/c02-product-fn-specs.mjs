// A product green for the C02 work (design §5.2): float specialisation
// is decided by *fn-specs*, a compiler table no compiled cell can see.
// A generic-but-correct implementation of binding identity -- one that
// resolves every name properly and simply never specialises -- passes
// every behavioural cell; only a reading of the product tells it apart.
//
// The instrument is Chez-hosted: it loads src/compiler.ss and reads the
// table after prepare-program.  Known answer: run's accumulator is f64
// and its counter is not.  With compute-fn-specs! disabled the reading
// is (), which is how this file was shown to be able to fail.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

test('run keeps an f64 accumulator and a non-float counter', () => {
    if (!chez) {
        console.log('NOT EXERCISED HERE (no chez on PATH; the fn-specs product instrument is Chez-hosted and this reading was NOT taken)');
        return;
    }
    const out = execFileSync(chez, ['--script', path.join(root, 'test/lib/c02-products.sc'), root,
                                   path.join(root, 'test/c02-products-fixture.ss')], { encoding: 'utf8' });
    const line = out.split('\n').find(l => l.startsWith('(fn-specs-after-prepare'));
    assert.ok(line, `no fn-specs line in:\n${out}`);
    assert.match(line, /\(run #f #t\)/, `run was not classified (#f #t):\n${line}`);
});
