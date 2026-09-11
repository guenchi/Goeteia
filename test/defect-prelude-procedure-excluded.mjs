// RED ON PURPOSE, row by row: a procedure the prelude defines in
// Scheme (append, length, ...) cannot yet be excluded from (rnrs) and
// redefined -- the prelude's definition and the program's would be one
// name at the flat top level, and the compiler refuses "defined
// twice".  Primitives can (car, fl+: the intrinsic lowering keeps the
// prelude's references on the primitive); prelude procedures need the
// coexistence of design section 28.  Each row is a legal R6RS program
// with the host's answer; the two twins hold what must not move.
// Readings on de7604c are in the comments.
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
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-prelproc-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, src + '\n');
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 120000 });
    if (!fs.existsSync(wasm)) { fs.rmSync(dir, { recursive: true, force: true }); return { refused: ((c.stdout || '') + (c.stderr || '')).trim().split('\n').filter(l => !l.startsWith('at ')).pop() }; }
    const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), wasm], { encoding: 'utf8', timeout: 20000 });
    fs.rmSync(dir, { recursive: true, force: true });
    return { out: ((r.stdout || '') + (r.stderr || '')).trim().split('\n')[0] };
}

const rows = [
    // the program's length is the program's; the prelude's list->vector
    // still calls the prelude's length.  Today: defined twice.
    ['length excluded and redefined; the prelude keeps its own',
     '(import (except (rnrs) length))\n(define (length . xs) (quote mine))\n(display (list (length (list 1 2)) (vector-length (list->vector (list 1 2 3)))))', { out: '(mine 3)' }],
    // a library excludes append, defines and exports its own; the
    // importing program calls the library's.  Today: defined twice.
    ['a library exports its own append and an importer calls it',
     '(import (except (rnrs) append))\n(begin\n  (library (mine) (export append) (import (except (rnrs) append)) (define (append . xs) (quote lib)))\n  (import (mine)))\n(display (append (quote (1)) (quote (2))))', { out: 'lib' }],
    // two libraries export f; the second is imported under a rename.
    // Today: defined twice at the flat top level.
    ['a rename separates two libraries\' exports of one spelling',
     '(import (rnrs))\n(begin\n  (library (a) (export f) (import (rnrs)) (define (f) 1))\n  (library (b) (export f) (import (rnrs)) (define (f) 2))\n  (import (a) (rename (b) (f g))))\n(display (list (f) (g)))', { out: '(1 2)' }],
    // an exported variable read under a renamed name.  Today: c unbound
    // -- the driver's aliases do not cover a variable export.
    ['a renamed variable export is an alias of the binding',
     '(import (rnrs))\n(begin\n  (library (v) (export counter) (import (rnrs)) (define counter 5))\n  (import (rename (v) (counter c))))\n(display c)', { out: '5' }],
    // a library macro introduces append into a program that excluded
    // and redefined it: the template\'s append is the prelude\'s, the
    // program\'s own call is its own.  Today: defined twice.
    ['a library macro\'s append stays the prelude\'s beside the program\'s',
     '(import (except (rnrs) append))\n(begin\n  (library (mac) (export app2) (import (rnrs)) (define-syntax app2 (syntax-rules () ((_ a b) (append a b)))))\n  (import (mac)))\n(define (append . xs) (quote mine))\n(display (list (app2 (quote (1)) (quote (2))) (append (quote (1)) (quote (2)))))', { out: '((1 2) mine)' }],
    // twins
    ['twin: the prelude\'s own append still works',
     '(import (rnrs))\n(display (append (list 1) (list 2) (list 3)))', { out: '(1 2 3)' }],
    // refused today for the prelude collision, which is the wrong
    // reason; after the coexistence lands it must still be refused,
    // for the right one -- two definitions in one scope
    ['twin: defining an excluded name twice is still refused',
     '(import (except (rnrs) append))\n(define (append . xs) 1)\n(define (append . xs) 2)\n(display (append))', { refused: /defined twice/ }],
];

for (const [title, src, want] of rows) {
    test(title, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
        const r = run(src);
        if ('out' in want) { assert.ok(!('refused' in r), `refused: ${r.refused}`); assert.equal(r.out, want.out); }
        else { assert.ok('refused' in r, `compiled and printed ${r.out}; expected a refusal`); assert.match(r.refused, want.refused); }
    });
}
