// The lets the expander generates for a let* or a letrec body are not
// captured by a program's own `let` macro where they were not before.
//
// To accept body definitions, an empty let* lowers to a let with no
// bindings (it was a begin), and letrec / letrec* wrap their body in one.
// A let the expander generates is looked up by its spelling, so a program
// that excludes (rnrs)'s let and defines a macro of that name could
// capture the NEW lets, which the tree before the change did not have:
//   - a macro that rewrites every let answered 99 for (let* () 7);
//   - a SELECTIVE macro -- a let with bindings passed through as a lambda
//     application, a let without them rewritten -- answered 99 for
//     (letrec ((a 7)) a), whose outer let it passes and whose new inner
//     (let () . body) it rewrites.
// The empty let*'s let goes straight to the core form; the letrec wrapper
// is added only when the program defines no let macro, so under one
// letrec is laid out as before.
//
// What this cell does NOT judge: under the catch-all macro, a let* WITH
// bindings, letrec, letrec*, a named let and do are captured on the tree
// before the change too -- every core form the expander generates is
// resolved by spelling.  That is the scope-aware keyword resolution item,
// a design of its own, and no row here pins those either way.
//
// The program cannot display its answer: a user macro named let also
// captures the lets inside display's own code.  So f is exported and
// called from node, and its value read as a fixnum (an i31 holding 2n).
// Each row is compiled by the Chez-hosted compiler and by the
// self-hosted one.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function call(wasm) {
    const m = new WebAssembly.Module(fs.readFileSync(wasm));
    const imports = {};
    for (const i of WebAssembly.Module.imports(m))
        if (i.kind === 'function') (imports[i.module] ||= {})[i.name] = () => 0;
    const v = new WebAssembly.Instance(m, imports).exports.f();
    return typeof v === 'number' ? v >> 1 : String(v);
}

const WAYS = [
    ['chez wasm', (s, o) => spawnSync(path.join(root, 'bin/goeteiac'), [s, o], { cwd: root, encoding: 'utf8', timeout: 120000 })],
    ['self wasm', (s, o) => spawnSync('node', [path.join(root, 'rt/compile.mjs'), path.join(root, 'goeteia.wasm'), s, o], { cwd: root, encoding: 'utf8', timeout: 120000 })],
];

const CATCH_ALL = '(define-syntax let (syntax-rules () ((_ . rest) 99)))';
// the selective macro needs its third rule: the program's own compiled
// code meets the macro too, and a named let there must still work
const SELECTIVE = `(define-syntax let
  (syntax-rules ()
    ((_ () body ...) 99)
    ((_ ((name val) ...) body ...) ((lambda (name ...) body ...) val ...))
    ((_ tag ((name val) ...) body ...) ((letrec ((tag (lambda (name ...) body ...))) tag) val ...))))`;

function f(macro, body) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-genlet-'));
    try {
        const ss = path.join(dir, 'p.ss');
        fs.writeFileSync(ss, '(import (except (rnrs) let))\n'
            + macro + '\n'
            + `(define (f) ${body})\n(export f)\n`);
        return WAYS.map(([way, compile], i) => {
            const out = path.join(dir, `p${i}.wasm`);
            const c = compile(ss, out);
            return [way, fs.existsSync(out) ? call(out)
                         : `NOT COMPILED: ${((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop()}`];
        });
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const rows = [
    // CONTROL: no let anywhere -- the harness reads 7 through export and call
    ['catch-all', CATCH_ALL, 'CONTROL a body with no let in it', '7'],
    ['catch-all', CATCH_ALL, 'an empty let*', '(let* () 7)'],
    ['catch-all', CATCH_ALL, 'an empty let* whose body opens with a definition', '(let* () (define (g) 7) (g))'],
    ['selective', SELECTIVE, 'CONTROL a body with no let in it', '7'],
    ['selective', SELECTIVE, 'an empty let*', '(let* () 7)'],
    ['selective', SELECTIVE, 'letrec', '(letrec ((a 7)) a)'],
    ['selective', SELECTIVE, 'letrec*', '(letrec* ((a 7)) a)'],
];

for (const [kind, macro, label, body] of rows) {
    test(`${kind} let macro: ${label}`, () => {
        assert.deepEqual(f(macro, body), WAYS.map(([w]) => [w, 7]));
    });
}
