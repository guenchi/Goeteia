// An import set may be built from another import set: R6RS 7.1 defines
// only, except, prefix and rename over an <import set>, not over a
// library name, so (except (only (rnrs) display car) car) is a legal
// import of display alone.
//
// Every nested form crashed the compiler instead.  The Chez-hosted
// driver took the second element of the clause for a library name and
// raised "symbol->string: (rnrs) is not a symbol"; the self-hosted
// compiler's driver did the same and raised a path error from node.
// Neither is a diagnosis of the program, and the program is legal.
//
// Each row is compiled four ways -- the Chez-hosted compiler to wasm
// and to JS, the self-hosted compiler to wasm and to JS -- and must
// print 7 under each.  Nesting is also read where it is not the
// program's own import: in an inline library's import, and in a
// library file the program loads, because the compiler reads a
// library's clause through a procedure of its own, apart from the two
// drivers.
//
// The last rows check that the nesting MEANS something, under all four
// ways: a name an inner set leaves out, or an outer set removes or
// renames away, is not bound.  Each refusal must fail the compile and
// name that identifier as unbound -- so neither the crash this cell was
// written for nor an unrelated failure satisfies it, and each program
// uses no other name the import leaves out.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const T = 120000;

function sh(cmd, args) {
    const c = spawnSync(cmd, args, { cwd: root, encoding: 'utf8', timeout: T });
    return { status: c.status, out: ((c.stdout || '') + (c.stderr || '')).trim() };
}

// [label, compile(src, out) -> result, run(out) -> result, extension]
const WAYS = [
    ['chez wasm', (s, o) => sh(path.join(root, 'bin/goeteiac'), [s, o]),
     o => sh('node', [path.join(root, 'rt/run.mjs'), o]), '.wasm'],
    ['chez js', (s, o) => sh(path.join(root, 'bin/goeteiac'), ['--js', s, o]),
     o => sh('node', [path.join(root, 'rt/runjs.mjs'), o]), '.js'],
    ['self wasm', (s, o) => sh('node', [path.join(root, 'rt/compile.mjs'), path.join(root, 'goeteia.wasm'), s, o]),
     o => sh('node', [path.join(root, 'rt/run.mjs'), o]), '.wasm'],
    ['self js', (s, o) => sh('node', [path.join(root, 'rt/compile.mjs'), '--js', path.join(root, 'goeteia.wasm'), s, o]),
     o => sh('node', [path.join(root, 'rt/runjs.mjs'), o]), '.js'],
];

function each(src, fn, files = {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-nest-'));
    try {
        for (const [rel, text] of Object.entries(files)) {
            fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
            fs.writeFileSync(path.join(dir, rel), text + '\n');
        }
        const ss = path.join(dir, 'p.ss');
        fs.writeFileSync(ss, src + '\n');
        return WAYS.map(([label, compile, run, ext], i) => {
            const out = path.join(dir, 'p' + i + ext);
            const c = compile(ss, out);
            return fn(label, c, fs.existsSync(out) ? run(out) : null);
        });
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const legal = [
    // CONTROL: the four ways read a plain, unnested set.  If this row is
    // red the harness is broken and no other row means anything.
    ['CONTROL a plain only', '(import (only (rnrs) display))', '(display 7)'],
    ['except of only',   '(import (except (only (rnrs) display car) car))',               '(display 7)'],
    ['only of except',   '(import (only (except (rnrs) car) display))',                   '(display 7)'],
    ['rename of only',   '(import (rename (only (rnrs) display) (display show)))',        '(show 7)'],
    ['prefix of only',   '(import (prefix (only (rnrs) display) r:))',                    '(r:display 7)'],
    ['only of prefix',   '(import (only (prefix (rnrs) r:) r:display))',                  '(r:display 7)'],
    ['only of rename',   '(import (only (rename (rnrs) (display show)) show))',           '(show 7)'],
    ['prefix of rename of only', '(import (prefix (rename (only (rnrs) display) (display show)) p:))', '(p:show 7)'],
    ['except of prefix', '(import (except (prefix (rnrs) r:) r:car))',                    '(r:display 7)'],
    ['three deep',       '(import (only (except (only (rnrs) display car) car) display))', '(display 7)'],
    // an inner set feeds the outer one its RENAMED name: the outer only
    // must find plus, which exists only after the rename
    ['rename then only, using an arithmetic name', '(import (only (rename (rnrs) (+ plus)) plus display))', '(display (plus 3 4))'],
    // a nested set beside a plain one in the same import form
    ['beside a plain import', '(import (only (rnrs) display) (prefix (only (rnrs) +) m:))', '(display (m:+ 3 4))'],
    // the import of an inline library, which the compiler reads itself
    ['in an inline library', '(import (rnrs))',
     '(begin (library (nest inl) (export f) (import (rnrs) (only (prefix (rnrs) r:) r:+)) (define (f) (r:+ 3 4))) (import (nest inl)))\n(display (f))'],
    // the import of a library file the program loads from its lib/
    ['in a library file', '(import (rnrs) (nest one))', '(display (f))',
     { 'lib/nest/one.ss': '(library (nest one) (export f) (import (rnrs) (only (prefix (rnrs) r:) r:+)) (define (f) (r:+ 3 4)))' }],
];

for (const [label, imp, body, files] of legal) {
    test(`legal: ${label}`, () => {
        const got = each(`${imp}\n${body}`, (way, c, r) =>
            [way, r ? r.out : `NOT COMPILED: ${c.out.split('\n').pop()}`], files);
        assert.deepEqual(got, WAYS.map(([w]) => [w, '7']));
    });
}

// What the nesting removes stays removed.
// quote is core syntax, bound without an import, so (quote (7)) adds
// no second name the import would have to bring in.
const removed = [
    ['car, brought in by only and taken out by except',
     '(import (except (only (rnrs) display car) car))\n(display (car (quote (7))))', 'car'],
    ['display, renamed away before an only that names the new name',
     '(import (only (rename (rnrs) (display show)) show))\n(display 7)', 'display'],
    ['an unprefixed name after prefix',
     '(import (only (prefix (rnrs) r:) r:display))\n(display 7)', 'display'],
    // an INNER filter stays a filter: what only leaves out, or except
    // takes out, does not come back under the outer prefix
    ['r:car, left out by an inner only',
     '(import (only (rnrs) display) (prefix (only (rnrs) display) r:))\n(display (r:car (quote (7))))', 'r:car'],
    ['r:car, taken out by an inner except',
     '(import (only (rnrs) display) (prefix (except (rnrs) car) r:))\n(display (r:car (quote (7))))', 'r:car'],
];

const esc = s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
for (const [label, src, name] of removed) {
    test(`removed: ${label}`, () => {
        const got = each(src, (way, c, r) => [way, c.status, r === null, r === null ? c.out : r.out]);
        for (const [way, status, refused, text] of got) {
            assert.ok(refused && status !== 0,
                      `${way}: the program compiled (status ${status}) and printed ${JSON.stringify(text)}`);
            assert.match(text, new RegExp(`unbound variable: ${esc(name)}(\\s|$)`),
                         `${way}: not the diagnosis of ${name}: ${text.split('\n').slice(-3).join(' | ')}`);
        }
    });
}
