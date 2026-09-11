// REGRESSION GUARD (written as a red witness at de7604c; green since),
// row by row: what a review of the import rule found it still gets
// wrong, each row a whole program with the answer R6RS gives. Two rows
// are green twins that record what the rule already gets right in the
// same family, so a fix for a red row is shown not to break them.
// Readings on ceb47bf are in each row's comment.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

function run(src) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-holes-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, src + '\n');
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 120000 });
    if (!fs.existsSync(wasm)) { fs.rmSync(dir, { recursive: true, force: true }); return { refused: ((c.stdout || '') + (c.stderr || '')).trim().split('\n').filter(l => !l.startsWith('at ')).pop() }; }
    const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), wasm], { encoding: 'utf8', timeout: 20000 });
    fs.rmSync(dir, { recursive: true, force: true });
    return { out: ((r.stdout || '') + (r.stderr || '')).trim().split('\n')[0] };
}

const LIB = (name, exports, imports, body) => `(library (${name}) (export ${exports}) (import ${imports}) ${body})`;

const rows = [
    // 1. re-export identity: a name imported directly and through a
    //    library that re-exports it is ONE binding.  Today: refused as
    //    "two different bindings imported under one name".
    ['a re-exported name is the same binding', '(import (rnrs))\n(begin\n' + LIB('a', 'f', '(rnrs)', '(define (f) 1)') + '\n' + LIB('b', 'f g', '(rnrs) (a)', '(define (g) 2)') + '\n(import (a) (b)))\n(display (+ (f) (g)))', { out: '3' }],
    // 2. the assignment walk: a parameter or an internal definition
    //    spelled like an imported name is the program's to assign.
    //    Today: refused as assigning an imported name.  Chez: 2.
    ['set! of a parameter named like an import', '(import (rnrs))\n(define (f car) (set! car 2) car)\n(display (f 1))', { out: '2' }],
    ['set! of an internal definition named like an import', '(import (rnrs))\n(define (f) (define car 1) (set! car 2) car)\n(display (f))', { out: '2' }],
    // 3. an introduced token is judged against its macro's own scope:
    //    a library whose clause excludes car cannot write car in a
    //    template.  Today: compiles and answers 9.
    ['a macro template is judged against its library\'s clause', '(import (rnrs))\n(begin\n' + LIB('m', 'first', '(except (rnrs) car)', '(define-syntax first (syntax-rules () ((_ x) (car x))))') + '\n(import (m)))\n(display (first (list 9)))', { refused: /unbound variable: car/ }],
    // 4. twins: a library's private definition of an imported name, and
    //    a record type whose generated names collide, are refused
    //    before private renaming hides them.  Green today.
    ['twin: a library privately defining an imported name is refused', '(import (rnrs))\n(begin\n' + LIB('p', 'f', '(rnrs)', '(define (car x) 42) (define (f) (car (list 1)))') + '\n(import (p)))\n(display (f))', { refused: /imported name may not be defined.*car/ }],
    ['twin: a library record colliding with an import is refused', '(import (rnrs))\n(begin\n' + LIB('q', 'f', '(rnrs)', '(define-record-type vector (fields ref)) (define (f) 1)') + '\n(import (q)))\n(display (f))', { refused: /imported name may not be defined.*make-vector/ }],
    // 5. a define-syntax inside a begin in a library body is a
    //    definition of the library and is refused like a top-level one.
    //    Today: compiles and answers 5.
    ['a define-syntax inside a begin in a library body is judged', '(import (rnrs))\n(begin\n' + LIB('s', 'f', '(rnrs)', '(begin (define-syntax case (syntax-rules () ((_ x) x)))) (define (f) (case 5))') + '\n(import (s)))\n(display (f))', { refused: /imported name may not be defined.*case/ }],
    // 6. a program with no import clause at all imports nothing, and
    //    R6RS says a program begins with an import form.  Today: never
    //    judged, compiles.  This row waits on the clause-ownership
    //    design (section 27.7): the drivers' marker decides what is
    //    recorded, and a program with no clause gets no marker.
    ['a program with no import clause imports nothing', '(define (dead) missing)\n(display 1)', { refused: /import/ }],
    // a second clause-less witness that USES a name (rnrs) would give,
    // so the empty-map rule has more than one row in the whole tree
    ['a clause-less program may not use a name (rnrs) would give', '(display 1)', { refused: /import|unbound variable: display/ }],
];

for (const [title, src, want] of rows) {
    test(title, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
        const r = run(src);
        if ('out' in want) { assert.ok(!('refused' in r), `refused: ${r.refused}`); assert.equal(r.out, want.out); }
        else { assert.ok('refused' in r, `compiled and printed ${r.out}; expected a refusal`); assert.match(r.refused, want.refused); }
    });
}
