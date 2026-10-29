// The self-hosted compiler reads a long list in its source.
//
// Its reader took one stack frame per list element, so a program holding
// a quoted list of a few thousand elements overflowed node's default
// stack while being READ ("Maximum call stack size exceeded", between
// 1,500 and 1,800 elements), before anything was compiled; walks after
// the reader (stripping marks, sorting the interned constants, the JS
// text) recursed the same way.  The Chez-hosted compiler reads with
// Chez's reader and never had the limit.  These now iterate along the
// list.
//
// Each row is compiled by the self-hosted compiler under node's default
// stack, to wasm and to JS, and run; the Chez-hosted compiler is the
// CONTROL.  The program checks its own data element by element against
// values it computes, IN ORDER, so a walk that reversed or dropped an
// element fails, not only one that lost the length.  The run must exit 0.
//
// Out of scope: a long list of CODE (thousands of arguments, or of body
// expressions) -- the expander and every later pass walk those, a
// separate item -- and nesting depth.
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
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-longlist-'));
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
// every element is checked against (mod (* i 7919) 256), in order; the
// answer is the count of elements that matched, then what is left
const checkNums = (name, count) =>
    `(let walk ((l ${name}) (i 0) (ok 0)) (if (pair? l) (walk (cdr l) (+ i 1) (if (= (car l) (mod (* i 7919) 256)) (+ ok 1) ok)) (list ok i l)))`;
const rows = [
    ['a quoted list of 20,000 numbers, in order',
     `(import (rnrs))\n(define data '(${nums.join(' ')}))\n(display ${checkNums('data')})\n`,
     `(${N} ${N} ())`],
    ['a quoted list of 20,000 symbols and strings, alternating, each by type and spelling',
     `(import (rnrs))\n(define data '(${Array.from({ length: N }, (_, i) => i % 2 ? `"s${i}"` : `y${i}`).join(' ')}))\n`
     + `(display (let walk ((l data) (i 0) (ok 0))\n`
     + `  (if (pair? l)\n`
     + `      (walk (cdr l) (+ i 1)\n`
     + `            (if (if (= (mod i 2) 1)\n`
     + `                    (and (string? (car l)) (string=? (car l) (string-append "s" (number->string i))))\n`
     + `                    (and (symbol? (car l)) (eq? (car l) (string->symbol (string-append "y" (number->string i))))))\n`
     + `                (+ ok 1) ok))\n`
     + `      (list ok i l))))\n`,
     `(${N} ${N} ())`],
    ['a vector literal of 9,000 numbers (under the 10,000 a wasm constant takes), in order',
     `(import (rnrs))\n(define data '#(${nums.slice(0, 9000).join(' ')}))\n`
     + `(display (let walk ((i 0) (ok 0)) (if (< i (vector-length data)) (walk (+ i 1) (if (= (vector-ref data i) (mod (* i 7919) 256)) (+ ok 1) ok)) (list ok i))))\n`,
     '(9000 9000)'],
    ['a dotted list of 20,000 elements, in order, with its tail',
     `(import (rnrs))\n(define data '(${nums.join(' ')} . end))\n(display ${checkNums('data')})\n`,
     `(${N} ${N} end)`],
];

for (const [label, src, expect] of rows) {
    for (const way of Object.keys(WAYS)) {
        test(`${way}: ${label}`, () => {
            assert.equal(run(src, way), expect);
        });
    }
}
