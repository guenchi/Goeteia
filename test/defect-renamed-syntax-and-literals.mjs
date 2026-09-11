// REGRESSION GUARD (written as a red witness at 64906b5; green since),
// row by row: a renamed syntactic keyword and a renamed library macro
// must resolve during expansion, and a syntax-rules literal must match
// by binding identity, not spelling. Each row is a legal R6RS program
// with Chez's answer; the twins record what already holds. Readings on
// 998327d are in the comments. These are the expansion-time half of
// design section 28 (28.2 and 28.3): the import map is built after
// expansion today, so a rename of syntax reaches nothing, and literal
// matching compares spellings.
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
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-rensyn-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, src + '\n');
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 120000 });
    if (!fs.existsSync(wasm)) { fs.rmSync(dir, { recursive: true, force: true }); return { refused: ((c.stdout || '') + (c.stderr || '')).trim().split('\n').filter(l => !l.startsWith('at ')).pop() }; }
    const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), wasm], { encoding: 'utf8', timeout: 20000 });
    fs.rmSync(dir, { recursive: true, force: true });
    return { out: ((r.stdout || '') + (r.stderr || '')).trim().split('\n')[0] };
}

const MAC = '(begin\n  (library (m) (export twice) (import (rnrs)) (define-syntax twice (syntax-rules () ((_ x) (+ x x)))))\n  (import (rename (m) (twice dbl))))\n';

const rows = [
    // a renamed core keyword is the keyword under its new name.
    // Today: "unbound variable: if" -- the rename reaches nothing.
    ['a renamed core keyword', '(import (rename (rnrs) (if when-else)))\n(display (when-else #t 1 2))', { out: '1' }],
    ['a renamed core keyword under a lexical shadow', '(import (rename (rnrs) (if when-else)))\n(display (let ((when-else (lambda (a b c) 9))) (when-else #t 1 2)))', { out: '9' }],
    // a renamed library macro is the macro under its new name.
    // Today: "cannot call: dbl".
    ['a renamed library macro', '(import (rnrs))\n' + MAC + '(display (dbl 4))', { out: '8' }],
    ['a renamed library macro under a lexical shadow', '(import (rnrs))\n' + MAC + '(display (let ((dbl (lambda (x) 0))) (dbl 4)))', { out: '0' }],  // NOT a twin: red, the macro-shadowing defect (defect-macro-name-lexically-shadowed.ss) seen through rename
    // syntax-rules literals match by binding identity.  A literal
    // written in the program where my-else is NOT bound (the program
    // imported it renamed) denotes a free identifier, and els denotes
    // the library's binding: no match, second clause -- Chez agrees.
    ['twin: a literal free in the program does not match a bound alias', '(import (rnrs))\n(begin\n  (library (l) (export my-else) (import (rnrs)) (define my-else 0))\n  (import (rename (l) (my-else els))))\n(define-syntax pick (syntax-rules (my-else) ((_ my-else) 1) ((_ x) 2)))\n(display (pick els))', { out: '2' }],
    // a lexically shadowed else is a different binding from the
    // literal else.  Today: matched by spelling, answers 1.
    ['a shadowed literal does not match', '(import (rnrs))\n(define-syntax pick (syntax-rules (else) ((_ else) 1) ((_ x) 2)))\n(display (let ((else 5)) (pick else)))', { out: '2' }],
    // two free identifiers of one spelling are the same free identifier
    ['twin: an unbound literal matches an unbound use', '(import (rnrs))\n(define-syntax pick (syntax-rules (zzz) ((_ zzz) 1) ((_ x) 2)))\n(display (pick zzz))', { out: '1' }],
];

for (const [title, src, want] of rows) {
    test(title, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
        const r = run(src);
        assert.ok(!('refused' in r), `refused: ${r.refused}`);
        assert.equal(r.out, want.out);
    });
}
