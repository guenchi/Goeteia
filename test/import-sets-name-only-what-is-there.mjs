// An import set that names an identifier its inner set does not provide is
// refused.
//
// R6RS 7.1: in (only S id ...), (except S id ...) and (rename S (id new)
// ...), each id must be in S's set of names -- naming one that is not is a
// syntax violation.  The compiler accepted the clause and ignored the name,
// so a misspelt except removed nothing and said nothing, and an only that
// named a missing identifier imported less than it appeared to.
//
// Each refusal must fail the compile on the Chez-hosted and the self-hosted
// compiler and name the identifier; so a crash, or any other refusal, does
// not satisfy it.  The CONTROLS are the same clauses with names the set
// does provide, which must compile and run to exit 0.  Clauses are read
// in a program's import, in an inline library's and in a library file's,
// and the set an outer clause is checked against is the inner one's as it
// stands -- after an inner rename, the NEW name is provided and the old
// one is not.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const WAYS = {
    chez: (s, o) => spawnSync(path.join(root, 'bin/goeteiac'), [s, o], { cwd: root, encoding: 'utf8', timeout: 120000 }),
    self: (s, o) => spawnSync('node', [path.join(root, 'rt/compile.mjs'), path.join(root, 'goeteia.wasm'), s, o], { cwd: root, encoding: 'utf8', timeout: 120000 }),
};

function attempt(src, way, files = {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-importname-'));
    try {
        for (const [rel, text] of Object.entries(files)) {
            fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
            fs.writeFileSync(path.join(dir, rel), text + '\n');
        }
        const ss = path.join(dir, 'p.ss'), out = path.join(dir, 'p.wasm');
        fs.writeFileSync(ss, src + '\n');
        const c = WAYS[way](ss, out);
        const text = ((c.stdout || '') + (c.stderr || '')).trim();
        if (c.status !== 0 || !fs.existsSync(out)) return { refused: true, text };
        const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), out], { cwd: root, encoding: 'utf8', timeout: 60000 });
        if (r.status !== 0 || r.error || r.signal)
            return { refused: false, text: `RUN FAILED (status ${r.status}, signal ${r.signal}): ${((r.stdout || '') + (r.stderr || '')).trim()}` };
        return { refused: false, text: (r.stdout || '').trim() };
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const refused = [
    ['only naming a missing identifier', '(import (only (rnrs) display nosuch))\n(display 7)', 'nosuch'],
    ['except naming a missing identifier', '(import (rnrs) (except (rnrs) nosuch))\n(display 7)', 'nosuch'],
    ['rename naming a missing identifier', '(import (rnrs) (rename (rnrs) (nosuch other)))\n(display 7)', 'nosuch'],
    ['only naming what an inner except removed', '(import (only (except (rnrs) car) display car))\n(display 7)', 'car'],
    ['except naming what an inner prefix renamed', '(import (rnrs) (except (prefix (rnrs) r:) car))\n(display 7)', 'car'],
    ['only naming the old name an inner rename freed', '(import (rnrs) (only (rename (rnrs) (car head)) car))\n(display 7)', 'car'],
    ['an inline library importing a missing identifier',
     "(import (rnrs))\n(begin (library (bad one) (export f) (import (except (rnrs) nosuch)) (define (f) 7)) (import (bad one)))\n(display (f))", 'nosuch'],
    ['a library file importing a missing identifier', '(import (rnrs) (bad two))\n(display (f))', 'nosuch',
     { 'lib/bad/two.ss': '(library (bad two) (export f) (import (only (rnrs) define display nosuch)) (define (f) 7))' }],
];
const controls = [
    ['CONTROL only naming provided identifiers', '(import (only (rnrs) display +))\n(display (+ 3 4))'],
    ['CONTROL except naming a provided identifier', '(import (except (rnrs) car))\n(display 7)'],
    ['CONTROL rename of a provided identifier', '(import (rename (rnrs) (display show)))\n(show 7)'],
    ['CONTROL except naming a prefixed identifier', '(import (rnrs) (except (prefix (rnrs) r:) r:car))\n(display 7)'],
    ['CONTROL only naming the new name of an inner rename', '(import (only (rename (rnrs) (display show)) show))\n(show 7)'],
    ['CONTROL an inline library whose import names provided identifiers',
     "(import (rnrs))\n(begin (library (good one) (export f) (import (except (rnrs) car)) (define (f) 7)) (import (good one)))\n(display (f))"],
    ['CONTROL a library file whose import names provided identifiers', '(import (rnrs) (good two))\n(display (f))',
     { 'lib/good/two.ss': '(library (good two) (export f) (import (only (rnrs) define)) (define (f) 7))' }],
];

for (const way of Object.keys(WAYS)) {
    for (const [label, src, files] of controls) {
        test(`${way}: ${label}`, () => {
            const a = attempt(src, way, files);
            assert.deepEqual(a, { refused: false, text: '7' });
        });
    }
    for (const [label, src, name, files] of refused) {
        test(`${way}: refused: ${label}`, () => {
            const a = attempt(src, way, files);
            assert.ok(a.refused, `${way}: compiled and printed ${JSON.stringify(a.text)}`);
            assert.match(a.text, new RegExp(`\\b${name}\\b`), `${way}: the refusal does not name ${name}: ${a.text.split('\n').slice(-2).join(' | ')}`);
            assert.doesNotMatch(a.text, /is not a symbol|"path" argument|Maximum call stack/, `${way}: a crash, not a diagnosis`);
        });
    }
}
