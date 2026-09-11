// What the import rule refuses, one program per row, read from the
// compiler's own message: a program that imports (rnrs) may not define
// or assign a name the import brings in, in any spelling, and a
// component library is refused by name.  Each row expects the refusal
// to name the import and the except spelling, since a refusal that
// names the prelude's definition -- "defined twice" -- points at
// something the author did not write.  The .ss runner has no way to
// expect a compile error, which is why these live here.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

function compileError(src) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-refuse-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, src + '\n');
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 120000 });
    const produced = fs.existsSync(wasm);
    fs.rmSync(dir, { recursive: true, force: true });
    return produced ? null : ((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop();
}

const rows = [
    ['define, function form',        '(import (rnrs))\n(define (car x) 99)',                     /imported name may not be defined; exclude it with except: car/],
    ['define, value form',           '(import (rnrs))\n(define car (lambda (x) 99))',            /imported name may not be defined; exclude it with except: car/],
    ['define-syntax of a keyword',   '(import (rnrs))\n(define-syntax case (syntax-rules () ((_ x) x)))', /imported name may not be defined; exclude it with except: case/],
    ['record whose name collides',   '(import (rnrs))\n(define-record-type vector (fields ref))', /imported name may not be defined; exclude it with except:/],
    ['set! of an imported variable', '(import (rnrs))\n(set! car 5)',                            /imported name may not be assigned; exclude it with except: car/],
    ['two bindings under one name',  '(import (rnrs) (rename (rnrs) (cdr car)))\n(display 1)',   /two different bindings imported under one name/],
    ['a component library',          '(import (rnrs base))\n(display 1)',                        /component libraries of \(rnrs\) are not supported/],
    // a library body is judged against its own clause
    // renaming a procedure ONTO a keyword's spelling brings two bindings
    // under one name (rnrs's if, and list renamed to if), which R6RS 7.2
    // makes an error; the collision check is authoritative and must stay
    // so when the expander becomes scope-aware.  Chez is permissive here.
    ['a rename onto a keyword spelling collides', '(import (rename (rnrs) (list if)))\n(display (if 1 2))', /two different bindings imported under one name/],
    ['a library defining a name it imports',  '(import (rnrs))\n(begin (library (o l) (export f) (import (rnrs)) (define (car x) 9) (define (f) 1)) (import (o l)))\n(display (f))', /imported name may not be defined; exclude it with except: car/],
    // a library the program does not define is still looked for on disk
    ['an import of a library that exists nowhere', '(import (rnrs) (no such lib))\n(display 1)',                                  /library not found: \(no such lib\)/],
    // an embed unit does not contain the host's inline libraries, so a
    // body importing one is refused the same way on both hosts
    ['an embed body importing the host\'s inline library', '(import (rnrs))\n(begin (library (t one) (export mk1) (import (rnrs)) (define (mk1) 1)) (import (t one)))\n(define s (conjure js (import (rnrs) (t one)) (display (mk1))))\n(display 1)', /library not found: \(t one\)/],
    ['a library assigning a name it imports', '(import (rnrs))\n(begin (library (o l) (export f) (import (rnrs)) (define (f) (set! car 5) 1)) (import (o l)))\n(display (f))',    /imported name may not be assigned; exclude it with except: car/],
];

for (const [title, src, want] of rows) {
    test(`refused: ${title}`, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
        const err = compileError(src);
        assert.ok(err !== null, 'the program compiled; it must be refused');
        assert.match(err, want);
    });
}

test('control: the same shapes compile once the name is excluded or fresh', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    assert.equal(compileError('(import (except (rnrs) car))\n(define (car x) 99)\n(display (car (list 1)))'), null);
    assert.equal(compileError('(import (rnrs))\n(define (fresh x) 99)\n(display (fresh 1))'), null);
    assert.equal(compileError('(import (rename (rnrs) (display show)))\n(show 7)'), null);
});
