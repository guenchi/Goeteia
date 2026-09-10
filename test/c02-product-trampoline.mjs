// A product green for the C02 work (design §5.2, decider site #14):
// trampoline elision.  A function whose tail is an unshadowed primitive
// application is classified not-bouncy, so its callers skip the TR
// wrapper; one whose tail calls a procedure parameter is bouncy.  A
// generic implementation of binding identity that stopped recognising
// the primitive in tail position would make prim-tail bouncy and every
// caller pay the wrapper -- and no behavioural cell would notice.
//
// The reading comes from the JS backend's own *jbouncy* table, through
// the Chez-hosted instrument, not from the emitted text: names are
// numeric in the emission and a literal marks the argument it sits in,
// not the call.  With jbouncy? made to answer #t for everything, the
// prim-tail row fails, which is how this file was shown able to fail.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

test('a primitive tail is not bouncy and a procedure-parameter tail is', () => {
    if (!chez) {
        console.log('NOT EXERCISED HERE (no chez on PATH; the jbouncy product instrument is Chez-hosted and this reading was NOT taken)');
        return;
    }
    const out = execFileSync(chez, ['--script', path.join(root, 'test/lib/c02-products.sc'), root,
                                   path.join(root, 'test/c02-trampoline-fixture.ss'), '--js', 'prim-tail', 'proc-tail'],
                             { encoding: 'utf8' });
    const line = out.split('\n').find(l => l.startsWith('(jbouncy'));
    assert.ok(line, `no jbouncy line in:\n${out}`);
    assert.match(line, /\(prim-tail \. #f\)/, `prim-tail was classified bouncy:\n${line}`);
    assert.match(line, /\(proc-tail \. #t\)/, `proc-tail was not classified bouncy:\n${line}`);
});
