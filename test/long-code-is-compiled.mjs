// The self-hosted compiler compiles a long list of CODE.
//
// A call with 20,000 arguments, or a body of 20,000 expressions, is
// walked by the expander and by every later pass, and each walk took one
// stack frame per element: under node's default stack the self-hosted
// compiler died with "Maximum call stack size exceeded" (embed-expand*
// first, then xpand*, walk-heads*, convert-assignments, the JS inliner's
// map-same, the wasm body's arg-chain).  The Chez-hosted compiler has a
// deeper stack and is the CONTROL.  These walks now iterate along the
// list.
//
// A body whose elements are variables named unquote, unquote-splicing
// or quasiquote is ordinary code: the expander's walk must not read such
// an element as the start of a quasiquote form unless the form has that
// shape, or it falls back to one stack frame per element.
//
// Two rows are shorter than 20,000, for time, not for depth: a top-level
// begin is spliced into 20,000 top-level forms, which the compiler
// handles in time quadratic in their number (8,000 compile in about
// 10 s, 20,000 in over a minute, on either compiler), and a wasm function with
// 20,000 statements takes V8's optimizing tier over a minute to compile
// (10,000 take a tenth of a second).  Both are recorded items of their
// own, and neither is about the stack: the shorter rows still overflowed
// it before this change.
//
// Each program checks its own values in order against values it
// computes, so a walk that reversed, dropped or duplicated an element
// fails, not only one that lost the length; the run must exit 0.
//
// Out of scope, and why the 20,000-argument call is not run on wasm: a
// wasm function type takes at most 1,000 parameters in V8, and a call of
// N arguments needs a type of N + 1, so any call of 1,000 or more
// arguments compiles to a module V8 refuses to instantiate -- from either
// compiler.  That is a calling-convention item of its own.  The long
// BODY rows need no such type and run on every way.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const T = { cwd: root, encoding: 'utf8', timeout: 300000 };
const goeteiac = path.join(root, 'bin/goeteiac');
const compileMjs = path.join(root, 'rt/compile.mjs');
const snapshot = path.join(root, 'goeteia.wasm');
const WAYS = {
    'chez wasm (control)': { c: (s, o) => spawnSync(goeteiac, [s, o], T), run: 'rt/run.mjs', ext: '.wasm' },
    'chez js (control)': { c: (s, o) => spawnSync(goeteiac, ['--js', s, o], T), run: 'rt/runjs.mjs', ext: '.mjs' },
    'self wasm': { c: (s, o) => spawnSync('node', [compileMjs, snapshot, s, o], T), run: 'rt/run.mjs', ext: '.wasm' },
    'self js': { c: (s, o) => spawnSync('node', [compileMjs, '--js', snapshot, s, o], T), run: 'rt/runjs.mjs', ext: '.mjs' },
};

function run(src, way) {
    const w = WAYS[way];
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-longcode-'));
    try {
        const ss = path.join(dir, 'p.ss'), out = path.join(dir, 'p' + w.ext);
        fs.writeFileSync(ss, src);
        const c = w.c(ss, out);
        if (c.status !== 0 || !fs.existsSync(out))
            return `NOT COMPILED (status ${c.status}): ${((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop()}`;
        const r = spawnSync('node', [path.join(root, w.run), out], { cwd: root, encoding: 'utf8', timeout: 120000 });
        if (r.status !== 0 || r.error || r.signal)
            return `RUN FAILED (status ${r.status}, signal ${r.signal}): ${((r.stdout || '') + (r.stderr || '')).trim().split('\n').pop()}`;
        return (r.stdout || '').trim();
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const N = 20000;
const val = i => (i * 7919) % 256;
const nums = Array.from({ length: N }, (_, i) => val(i));
const checkList = name =>
    `(let walk ((l ${name}) (i 0) (ok 0)) (if (pair? l) (walk (cdr l) (+ i 1) (if (= (car l) (mod (* i 7919) 256)) (+ ok 1) ok)) (list ok i l)))`;
// a body that pushes val(i) for i = 0 .. n-1, one set! per expression,
// then checks the list it built, in order, after reversing it once
const pushesOf = n => nums.slice(0, n).map(v => `(set! acc (cons ${v} acc))`).join('\n  ');
const pushes = pushesOf(N);
const NBEGIN = 8000, NLET = 10000;
const JS = ['chez js (control)', 'self js'];
const ALL = Object.keys(WAYS);
const rows = [
    ['a call of list with 20,000 arguments, in order', JS,
     `(import (rnrs))\n(define data (list ${nums.join(' ')}))\n(display ${checkList('data')})\n`,
     `(${N} ${N} ())`],
    ['a call of a variadic user procedure with 20,000 arguments', JS,
     `(import (rnrs))\n(define (keep . xs) xs)\n(define data (keep ${nums.join(' ')}))\n(display ${checkList('data')})\n`,
     `(${N} ${N} ())`],
    ['a procedure body of 20,000 assignments, in order', ALL,
     `(import (rnrs))\n(define (build)\n  (define acc '())\n  ${pushes}\n  (reverse acc))\n(define data (build))\n(display ${checkList('data')})\n`,
     `(${N} ${N} ())`],
    ['a begin of 8,000 assignments at the top of the program, in order', ALL,
     `(import (rnrs))\n(define acc '())\n(begin\n  ${pushesOf(NBEGIN)})\n(define data (reverse acc))\n(display ${checkList('data')})\n`,
     `(${NBEGIN} ${NBEGIN} ())`],
    ['a let body of 10,000 assignments, in order', ALL,
     `(import (rnrs))\n(define data (let ((acc '()))\n  ${pushesOf(NLET)}\n  (reverse acc)))\n(display ${checkList('data')})\n`,
     `(${NLET} ${NLET} ())`],
    ...['unquote', 'unquote-splicing', 'quasiquote'].map(name =>
        [`a let body of 20,000 references to a variable named ${name}`, ALL,
         `(import (rnrs))\n(define (run) (let ((${name} 7)) ${Array(N).fill(name).join(' ')}))\n(display (run))\n`,
         '7']),
    // CONTROL: the same names quoted are data, whatever the walk does
    ['a quoted list of 20,000 unquote symbols', ALL,
     `(import (rnrs))\n(display (length '(${Array(N).fill('unquote').join(' ')})))\n`,
     `${N}`],
];

for (const [label, ways, src, expect] of rows) {
    for (const way of ways) {
        test(`${way}: ${label}`, () => {
            assert.equal(run(src, way), expect);
        });
    }
}
