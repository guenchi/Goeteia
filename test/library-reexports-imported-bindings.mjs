// A library can export a binding it imports -- under its own name, under
// a name its import set gave it (rename, prefix), and from (rnrs) -- as
// R6RS allows.
//
// The export check compared each exported name with every definition in
// the flattened program, never with the library's own import clauses.  A
// plain re-export passed only because the origin library happened to
// define the same name; renamed, prefixed and (rnrs) re-exports were
// refused with "library exports a name nothing defines".  The check now
// also accepts a name the library's own imports trace to another binding.
//
// Row 13 needs the R3 repair too: a two-part library's keyed name is
// spelt one way where it is defined and another where it is referenced
// (test/defect-inline-library-export-crashes-the-compiler.mjs).
//
// A name the library neither defines itself nor receives from its own
// imports is refused, even when another scope defines it: exporting f
// from (only (a) h), from (except (a) f), or from (rename (a) (f g)).
// The check used to ask whether ANY scope defined the name, so all
// three compiled and the export was a name the library did not have.
// It now asks whether this library defines it, or its clauses trace it
// to another binding.  A name defined nowhere is refused as before.
//
// What this cell does NOT judge: a macro exported by a library that
// neither defines nor imports it is still found in one table for every
// scope; no row pins that either way.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';

const root = path.join(path.dirname(url.fileURLToPath(import.meta.url)), '..');

// Both compilers: the Chez-hosted one and the self-hosted goeteia.wasm.
const WAYS = [
    ['chez', (ss, out) => spawnSync(path.join(root, 'bin/goeteiac'), [ss, out],
                                    { cwd: root, encoding: 'utf8', timeout: 120000 })],
    ['self', (ss, out) => spawnSync('node', [path.join(root, 'rt/compile.mjs'),
                                             path.join(root, 'goeteia.wasm'), ss, out],
                                    { cwd: root, encoding: 'utf8', timeout: 120000 })],
];

// For each compiler: ['ran', <last line the program printed>] when it
// compiled, otherwise ['refused', <everything the compiler said>].  The
// self-hosted compiler ends every refusal with "compile failed:
// unreachable" after the message itself, so a refusal is judged on the
// whole text, never on its last line.
function outcomes(src) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-reexport-'));
    try {
        const ss = path.join(dir, 'p.ss');
        fs.writeFileSync(ss, src + '\n');
        return WAYS.map(([way, compile], i) => {
            const out = path.join(dir, `p${i}.wasm`);
            const c = compile(ss, out);
            if (!fs.existsSync(out))
                return [way, 'refused', ((c.stdout || '') + (c.stderr || '')).trim()];
            const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), out],
                                { cwd: root, encoding: 'utf8', timeout: 120000 });
            return [way, 'ran', ((r.stdout || '') + (r.stderr || '')).trim().split('\n').pop()];
        });
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function runs(src, want) {
    assert.deepEqual(outcomes(src), WAYS.map(([w]) => [w, 'ran', want]));
}

function refused(src, message) {
    for (const [way, how, said] of outcomes(src)) {
        assert.equal(how, 'refused', `${way}: compiled, and should not have`);
        assert.ok(said.includes(message), `${way}: refused, but not with "${message}": ${said}`);
    }
}

const rows = [
    [
        "a renamed import is re-exported",
        "(library (a) (export f) (import (rnrs)) (define (f) 7))\n(library (b) (export g) (import (rename (a) (f g))))\n(import (b))\n(display (g))",
        "7"
    ],
    [
        "CONTROL a plain re-export (worked before, by coincidence)",
        "(library (a) (export f) (import (rnrs)) (define (f) 7))\n(library (b) (export f) (import (a)))\n(import (b))\n(display (f))",
        "7"
    ],
    [
        "a prefixed import is re-exported under its prefixed name",
        "(library (a) (export f) (import (rnrs)) (define (f) 7))\n(library (b) (export a:f) (import (prefix (a) a:)))\n(import (b))\n(display (a:f))",
        "7"
    ],
    [
        "CONTROL a re-export through only",
        "(library (a) (export f h) (import (rnrs)) (define (f) 7) (define (h) 0))\n(library (b) (export f) (import (only (a) f)))\n(import (b))\n(display (f))",
        "7"
    ],
    [
        "CONTROL a re-export through except",
        "(library (a) (export f h) (import (rnrs)) (define (f) 7) (define (h) 0))\n(library (b) (export f) (import (except (a) h)))\n(import (b))\n(display (f))",
        "7"
    ],
    [
        "CONTROL a macro re-exported under its own name",
        "(library (a) (export m) (import (rnrs)) (define-syntax m (syntax-rules () ((_ x) (+ x 4)))))\n(library (b) (export m) (import (a)))\n(import (b))\n(display (m 3))",
        "7"
    ],
    [
        "a macro re-exported under a new name",
        "(library (a) (export m) (import (rnrs)) (define-syntax m (syntax-rules () ((_ x) (+ x 4)))))\n(library (b) (export n) (import (rename (a) (m n))))\n(import (b))\n(display (n 3))",
        "7"
    ],
    [
        "a third library uses the re-exported name",
        "(library (a) (export f) (import (rnrs)) (define (f) 7))\n(library (b) (export g) (import (rename (a) (f g))))\n(library (c) (export k) (import (rnrs) (b)) (define (k) (g)))\n(import (c))\n(display (k))",
        "7"
    ],
    [
        "a program imports the origin and the re-exporter, both names",
        "(library (a) (export f) (import (rnrs)) (define (f) 7))\n(library (b) (export g) (import (rename (a) (f g))))\n(import (a) (b))\n(display (list (f) (g)))",
        "(7 7)"
    ],
    [
        "a binding of (rnrs) is re-exported",
        "(library (b) (export car) (import (rnrs)))\n(import (except (rnrs) car) (b))\n(display (car (quote (7))))",
        "7"
    ],
    [
        "a binding of (rnrs) is re-exported under a new name",
        "(library (b) (export first) (import (rename (only (rnrs) car) (car first))))\n(import (b))\n(display (first (quote (7))))",
        "7"
    ],
    [
        "CONTROL a plain re-export between libraries with two-part names",
        "(library (a one) (export f) (import (rnrs)) (define (f) 7))\n(library (b two) (export f) (import (a one)))\n(import (b two))\n(display (f))",
        "7"
    ],
    [
        "a renamed re-export from a two-part library whose name another scope also defines",
        "(library (a one) (export f) (import (rnrs)) (define (f) 7))\n(library (z zz) (export f) (import (rnrs)) (define (f) 0))\n(library (b two) (export g) (import (rename (a one) (f g))))\n(import (b two) (prefix (z zz) z:))\n(display (g))",
        "7"
    ],
    [
        "a renamed re-export from a one-part library whose name another scope also defines",
        "(library (a) (export f) (import (rnrs)) (define (f) 7))\n(library (z) (export f) (import (rnrs)) (define (f) 0))\n(library (b) (export g) (import (rename (a) (f g))))\n(import (b) (prefix (z) z:))\n(display (g))",
        "7"
    ],
    [
        "CONTROL the origin and a plain re-exporter imported together are one binding",
        "(library (a) (export f) (import (rnrs)) (define (f) 7))\n(library (b) (export f) (import (a)))\n(import (a) (b))\n(display (f))",
        "7"
    ],
    [
        "CONTROL a library re-exports an import and defines beside it",
        "(library (a) (export f) (import (rnrs)) (define (f) 3))\n(library (b) (export f g) (import (rnrs) (a)) (define (g) (+ (f) 4)))\n(import (b))\n(display (g))",
        "7"
    ]
];

for (const [label, src, want] of rows)
    test(label, () => runs('(import (rnrs))\n' + src, want));

test("an export that the only clause of the library leaves out is refused", () => {
    refused('(import (rnrs))\n' + "(library (a) (export f h) (import (rnrs)) (define (f) 7) (define (h) 0))\n(library (b) (export f) (import (only (a) h)))\n(import (b))\n(display 7)",
            'library exports a name nothing defines: f');
});

test("an export that the except clause of the library removes is refused", () => {
    refused('(import (rnrs))\n' + "(library (a) (export f h) (import (rnrs)) (define (f) 7) (define (h) 0))\n(library (b) (export f) (import (except (a) f)))\n(import (b))\n(display 7)",
            'library exports a name nothing defines: f');
});

test("an export under the name a rename clause of the library renamed away is refused", () => {
    refused('(import (rnrs))\n' + "(library (a) (export f) (import (rnrs)) (define (f) 7))\n(library (b) (export f) (import (rename (a) (f g))))\n(import (b))\n(display 7)",
            'library exports a name nothing defines: f');
});

test('CONTROL a name nothing defines or imports is still refused', () => {
    refused('(import (rnrs))\n' + "(library (b) (export zz) (import (rnrs)))\n(import (b))\n(display 7)",
            'library exports a name nothing defines');
});
