// Programs of many definitions compile in time linear in their number.
//
// Several passes kept, for every form or every reference, a list with an
// entry per definition and searched it: where each form came from, the
// names each scope defines, the names already defined (duplicates), the
// definitions and the live set of dead-code pruning -- whose reference
// walk also searched the whole work queue -- the known pure names, the
// definition a specialized call refers to, and the inlining candidates.
// A chain of 20,000 definitions, each referring to the one before, took
// 12 to 26 s to compile; 40,000 plain definitions about 20 s.  Each is
// a table now.
//
// The bound is a ceiling, not a benchmark: 8 s per compile by the
// Chez-hosted compiler, against 1 to 3 s after the change.  It is the
// Chez-hosted compiler that is timed, because it compiles the same
// source the self-hosted one is built from and its time is steadier;
// the self-hosted rows check the same programs compile and run, under a
// wider bound and at most 20,000 definitions: the self-hosted compiler
// still finds a form's source location in a table keyed by the form,
// and its runtime hashes every pair to one bucket, so that lookup stays
// linear there (a separate item).  Wasm is compiled, not run: a wasm main of tens of
// thousands of statements is slow in V8's optimizing tier, which is
// another item.  The backend's own tables (*vars*, *fns*) are not in
// this change; they cost about a second at these sizes.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CHEZ_BOUND_MS = 8000;
const SELF_BOUND_MS = 45000;
const goeteiac = path.join(root, 'bin/goeteiac');
const compileMjs = path.join(root, 'rt/compile.mjs');
const snapshot = path.join(root, 'goeteia.wasm');
const WAYS = {
    'chez js': { bound: CHEZ_BOUND_MS, ext: '.mjs', run: true, args: (s, o) => [goeteiac, ['--js', s, o]] },
    'chez wasm': { bound: CHEZ_BOUND_MS, ext: '.wasm', run: false, args: (s, o) => [goeteiac, [s, o]] },
    'self js': { bound: SELF_BOUND_MS, maxN: 20000, ext: '.mjs', run: true, args: (s, o) => ['node', [compileMjs, '--js', snapshot, s, o]] },
};

function outcome(src, way) {
    const w = WAYS[way];
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-manydefs-'));
    try {
        const ss = path.join(dir, 'p.ss'), out = path.join(dir, 'p' + w.ext);
        fs.writeFileSync(ss, src);
        const [cmd, args] = w.args(ss, out);
        const c = spawnSync(cmd, args, { cwd: root, encoding: 'utf8', timeout: w.bound });
        if (c.error || c.signal) return `NOT COMPILED within ${w.bound} ms`;
        if (c.status !== 0 || !fs.existsSync(out))
            return `NOT COMPILED (status ${c.status}): ${((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop()}`;
        if (!w.run) return 'compiled';
        const r = spawnSync('node', [path.join(root, 'rt/runjs.mjs'), out], { cwd: root, encoding: 'utf8', timeout: 60000 });
        if (r.status !== 0 || r.error || r.signal)
            return `RUN FAILED (status ${r.status}): ${((r.stdout || '') + (r.stderr || '')).trim().split('\n').pop()}`;
        return (r.stdout || '').trim();
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const span = n => Array.from({ length: n }, (_, i) => i);
// every step-th of n definitions is read back, 300 in all
const step = n => Math.floor(n / 300);
const rows = [
    // 40,000 values, a few hundred of them read back
    ['40,000 definitions of values', 40000,
     n => `(import (rnrs))\n${span(n).map(i => `(define x${i} ${i % 251})`).join('\n')}\n`
        + `(display (list ${span(300).map(i => `x${i * step(n)}`).join(' ')}))\n`,
     n => `(${span(300).map(i => (i * step(n)) % 251).join(' ')})`],
    ['40,000 definitions of procedures', 40000,
     n => `(import (rnrs))\n${span(n).map(i => `(define (f${i}) ${i % 251})`).join('\n')}\n`
        + `(display (list ${span(300).map(i => `(f${i * step(n)})`).join(' ')}))\n`,
     n => `(${span(300).map(i => (i * step(n)) % 251).join(' ')})`],
    // each definition refers to the one before
    ['a chain of 20,000 value definitions', 20000,
     n => `(import (rnrs))\n(define x0 0)\n${span(n - 1).map(i => `(define x${i + 1} (+ x${i} 1))`).join('\n')}\n(display x${n - 1})\n`,
     n => `${n - 1}`],
    ['a chain of 20,000 procedure definitions', 20000,
     // the last is referred to, which keeps the whole chain alive, but not
     // called: calling it would recurse 20,000 deep when the program runs
     n => `(import (rnrs))\n(define (f0) 0)\n${span(n - 1).map(i => `(define (f${i + 1}) (+ (f${i}) 1))`).join('\n')}\n(display (list (procedure? f${n - 1}) (f3)))\n`,
     n => '(#t 3)'],
];

for (const [label, n, prog, want] of rows) {
    for (const way of Object.keys(WAYS)) {
        const m = Math.min(n, WAYS[way].maxN ?? n);
        test(`${way}: ${label}${m < n ? ` (${m} of them here)` : ''}`, () => {
            assert.equal(outcome(prog(m), way), WAYS[way].run ? want(m) : 'compiled');
        });
    }
}
