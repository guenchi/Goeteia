// A program of 20,000 top-level forms compiles in seconds.
//
// Compile time grew with the square of the number of top-level forms --
// a top-level begin of set!s, separate defines, or bare expressions alike:
// 5,000 took about 5 s, 10,000 about 17 s, 20,000 one to two minutes, on
// either compiler.  For every form, the pass that gives each scope's
// definitions their keys folded over every form again; the lookup of a
// name among its scope's definitions and the check for names defined in
// two scopes were linear scans per name.  Each is now built once, or
// looked up in a table.
//
// The bound is a ceiling, not a benchmark: 45 s per compile, against
// 2 to 19 s after the change (the self-hosted compiler is the slower)
// and well over a minute before it.  A compile
// past it is killed and the row fails.  The rows compile to JS and run
// it; a wasm main of 20,000 statements is slow in V8's optimizing tier,
// which is another item.  Each program checks its values in order.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const BOUND_MS = 45000;
const WAYS = {
    'chez js': (s, o) => spawnSync(path.join(root, 'bin/goeteiac'), ['--js', s, o],
                                   { cwd: root, encoding: 'utf8', timeout: BOUND_MS }),
    'self js': (s, o) => spawnSync('node', [path.join(root, 'rt/compile.mjs'), '--js',
                                            path.join(root, 'goeteia.wasm'), s, o],
                                   { cwd: root, encoding: 'utf8', timeout: BOUND_MS }),
};

function compileAndRun(src, way) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-toplevel-'));
    try {
        const ss = path.join(dir, 'p.ss'), out = path.join(dir, 'p.mjs');
        fs.writeFileSync(ss, src);
        const t0 = Date.now();
        const c = WAYS[way](ss, out);
        const ms = Date.now() - t0;
        if (c.error || c.signal)
            return `NOT COMPILED within ${BOUND_MS} ms (${c.error ? c.error.code : c.signal})`;
        if (c.status !== 0 || !fs.existsSync(out))
            return `NOT COMPILED (status ${c.status}, ${ms} ms): ${((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop()}`;
        const r = spawnSync('node', [path.join(root, 'rt/runjs.mjs'), out], { cwd: root, encoding: 'utf8', timeout: 60000 });
        if (r.status !== 0 || r.error || r.signal)
            return `RUN FAILED (status ${r.status}): ${((r.stdout || '') + (r.stderr || '')).trim().split('\n').pop()}`;
        return (r.stdout || '').trim();
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const N = 20000;
const val = i => (i * 7919) % 256;
const idx = Array.from({ length: N }, (_, i) => i);
const checkList = name =>
    `(let walk ((l ${name}) (i 0) (ok 0)) (if (pair? l) (walk (cdr l) (+ i 1) (if (= (car l) (mod (* i 7919) 256)) (+ ok 1) ok)) (list ok i l)))`;
const rows = [
    ['a top-level begin of 20,000 assignments',
     `(import (rnrs))\n(define acc '())\n(begin\n  ${idx.map(i => `(set! acc (cons ${val(i)} acc))`).join('\n  ')})\n`
     + `(define data (reverse acc))\n(display ${checkList('data')})\n`],
    ['20,000 top-level definitions',
     `(import (rnrs))\n${idx.map(i => `(define x${i} ${val(i)})`).join('\n')}\n`
     + `(define data (list ${idx.slice(0, 900).map(i => `x${i}`).join(' ')}))\n`
     + `(define last (list x${N - 1} x${N - 2}))\n`
     + `(display (list ${checkList('data')} last))\n`,
     `((900 900 ()) (${val(N - 1)} ${val(N - 2)}))`],
    ['20,000 top-level expressions',
     `(import (rnrs))\n(define acc '())\n${idx.map(i => `(set! acc (cons ${val(i)} acc))`).join('\n')}\n`
     + `(define data (reverse acc))\n(display ${checkList('data')})\n`],
];

for (const [label, src, expect] of rows) {
    for (const way of Object.keys(WAYS)) {
        test(`${way}: ${label}`, () => {
            assert.equal(compileAndRun(src, way), expect ?? `(${N} ${N} ())`);
        });
    }
}
