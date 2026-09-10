// The JS backend's copy of the wasm cost cell: a predicate whose head
// the lowering replaced with an intrinsic record must take the same
// fast path as the written one, and a call through such a head must
// not be treated as an indirect call that needs a trampoline wrapper.
// The same function is written in a library (heads lowered) and in the
// program (heads written), each as its own program; the emitted JS
// texts must agree on the number of NIL tests, of boxed-then-unboxed
// predicate tests, and of TR( wrappers.  The prelude contributes
// equally to both, so the difference is the copy's alone.  Text is
// compared only by counting these three markers.
// Measured with compiler 4d60f6e9 (head-op on the wasm side only):
// the library copy carried the boxed test and a TR( its twin lacked.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

const LIB = `(import (rnrs))
(begin
  (library (o l)
    (export lib-len)
    (import (rnrs))
    (define (lib-len xs) (if (null? xs) 0 (+ 1 (lib-len (cdr xs))))))
  (import (o l)))
(display (lib-len (list 1 2 3)))
`;
const PROG = `(import (rnrs))
(define (prog-len xs) (if (null? xs) 0 (+ 1 (prog-len (cdr xs)))))
(display (prog-len (list 1 2 3)))
`;

function jsOf(src) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-jshead-'));
    const ss = path.join(dir, 'p.ss');
    const js = path.join(dir, 'p.js');
    fs.writeFileSync(ss, src);
    execFileSync(path.join(root, 'bin/goeteiac'), ['--js', ss, js], { stdio: 'ignore' });
    assert.ok(fs.existsSync(js), 'the fixture did not compile');
    const out = execFileSync('node', [path.join(root, 'rt/runjs.mjs'), js], { encoding: 'utf8' }).trim();
    assert.equal(out, '3', 'the fixture must run before its text is compared');
    const text = fs.readFileSync(js, 'utf8');
    fs.rmSync(dir, { recursive: true, force: true });
    const count = (re) => (text.match(re) || []).length;
    return { boxed: count(/\?TRUE:FALSE\)!==FALSE/g), nil: count(/===NIL/g), tr: count(/\bTR\(/g) };
}

test('a lowered head takes the same JS fast paths as the written one', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    const a = jsOf(LIB), b = jsOf(PROG);
    assert.deepEqual(a, b, `library copy ${JSON.stringify(a)} vs program copy ${JSON.stringify(b)}: the prelude contributes equally to both, so any difference is the lowered head's`);
});
