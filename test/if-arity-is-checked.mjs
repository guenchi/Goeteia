// An if with more than three parts after the keyword, or fewer than
// two, is refused at compile time with a diagnostic about the if.
//
// THE DEFECT.  The compiler read an if as (if test then else), taking
// cadr, caddr and cadddr, and never looked past the third part:
// (if #t 'two 'three 'FOURTH) compiled and answered two, and everything
// after the third part was never compiled at all.  (if #t) and (if)
// died inside the compiler with "incorrect list structure", which names
// a list operation of the compiler's own, not the source.  It was found
// when a source rewrite produced a four-part if, the compiler accepted
// and ran it, and the rewrite looked as if it were swallowing a failure
// when it was the compiler that was.
//
// SIX PLACES READ AN IF (src/compiler.ss: the macro transformer
// evaluator, the loop check, the wasm code generator; src/js-backend.ss:
// the two expression compilers and the trampoline scan), and an if
// reaches them by many routes: written in source or produced by a
// macro, in a lambda, a definition, an internal definition, a library
// body, a conjure body, an unquote, a transformer, a loop body, a
// definition nothing calls.  The rows cover each route rather than each
// reader, so that a check added to some readers and not others, or to
// the written source and not to what macros produce, or after dead-code
// pruning rather than during expansion, is seen.
//
// FIVE COMPILERS: the Chez-hosted compiler to wasm and to JS, and the
// self-hosted one (rt/compile.mjs with goeteia.wasm) to wasm, to JS and
// unoptimized -- the last because the loop check runs only when
// optimizing, so the named-let route differs.  The self-hosted compiler
// is the source compiled by itself and is only as fixed as its last
// rebuild.
//
// WHAT A REFUSAL ROW ASKS: the compiler exits unsuccessfully, writes no
// output file, and its message -- with this cell's own temporary paths
// removed -- names if and names none of the compiler's own list
// operations (car, cdr, cadr, ...).  The wording is the
// implementation's to choose.
//
// WHAT A CONTROL ROW ASKS: the program compiles AND runs AND prints what
// it should.  Among the controls are the legitimate uses a too-broad
// check would break: an if inside quoted data, a case key spelled if,
// and
// (gfx glsl)'s own if, which is n-ary by design and lives in quoted
// shader forms the Scheme compiler never evaluates.  A reader-based
// census of the tree (2026-09-18, re-run on 6ac5df6 by codex on
// 2026-10-21) found 16 such hits and no executable malformed if.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const snapshot = path.join(root, 'goeteia.wasm');
const node = process.execPath;

// [label, target, argv builder (in, out) -> [cmd, args]]
const COMPILERS = [
    ['stage0 wasm', 'wasm', (i, o) => [path.join(root, 'bin/goeteiac'), [i, o]]],
    ['stage0 js', 'js', (i, o) => [path.join(root, 'bin/goeteiac'), ['--js', i, o]]],
    ['stage1 wasm', 'wasm', (i, o) => [node, [path.join(root, 'rt/compile.mjs'), snapshot, i, o]]],
    ['stage1 js', 'js', (i, o) => [node, [path.join(root, 'rt/compile.mjs'), '--js', snapshot, i, o]]],
    ['stage1 wasm -O0', 'wasm', (i, o) => [node, [path.join(root, 'rt/compile.mjs'), '-O0', snapshot, i, o]]],
];

function compile(src, compiler) {
    const [, target, build] = compiler;
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-arity-'));
    const ss = path.join(dir, 'p.ss');
    const out = path.join(dir, target === 'js' ? 'p.js' : 'p.wasm');
    fs.writeFileSync(ss, src + '\n');
    const [cmd, args] = build(ss, out);
    const c = spawnSync(cmd, args, { encoding: 'utf8', timeout: 120000 });
    const produced = fs.existsSync(out) && fs.statSync(out).size > 0;
    let ran = null;
    if (produced && c.status === 0) {
        const runner = target === 'js' ? 'rt/runjs.mjs' : 'rt/run.mjs';
        const r = spawnSync(node, [path.join(root, runner), out], { encoding: 'utf8', timeout: 120000 });
        ran = { status: r.status, stdout: (r.stdout || '').trim() };
    }
    // the cell's own temporary paths are not the compiler's words
    const text = ((c.stdout || '') + '\n' + (c.stderr || '')).split(dir).join('<tmp>').trim();
    fs.rmSync(dir, { recursive: true, force: true });
    return { produced, status: c.status, text, ran };
}

const REFUSED = [
    // written in source, direct
    ['four parts', "(display (if #t 'two 'three 'FOURTH))"],
    ['five parts, the else taken', "(display (if #f 'two 'three 'FOURTH 'FIFTH))"],
    ['a test and no consequent', "(display (if #t))"],
    ['nothing at all', "(display (if))"],
    // positions
    ['in a function body, self-recursive (the JS trampoline scan)',
     "(define (f n) (if (= n 0) 'done (f (- n 1)) 'extra))\n(display (f 3))"],
    ['in a lambda body', "(display ((lambda () (if #t 1 2 3))))"],
    ['in an internal definition', "(define (g) (define (h) (if #t 1 2 3)) (h))\n(display (g))"],
    ['as the right side of set!', "(define x 0)\n(set! x (if #t 1 2 3))\n(display x)"],
    ['as the test of another if', "(display (if (if #t #t #f #f) 1 2))"],
    ['in a definition nothing calls', "(define (unused) (if #t 1 2 3))\n(display 1)"],
    ['under an unquote', "(display `(a ,(if #t 1 2 3)))"],
    ['in a named-let loop body', "(display (let loop ((i 0)) (if (< i 3) (loop (+ i 1)) 'done 'extra)))"],
    ['in a named-let loop body, too few parts', "(display (let loop ((i 0)) (if (< i 3))))"],
    ['in a library body',
     "(begin (library (t l) (export f) (import (rnrs)) (define (f) (if #t 1 2 3))) (import (t l)))\n(display (f))"],
    ['in a conjure body', "(define s (conjure js (import (rnrs)) (display (if #t 1 2 3))))\n(display 1)"],
    // produced by a macro
    ['produced by syntax-rules', "(define-syntax m (syntax-rules () ((_) (if #t 1 2 3))))\n(display (m))"],
    ['produced by syntax-rules, too few parts', "(define-syntax m (syntax-rules () ((_) (if #t))))\n(display (m))"],
    ['under a renamed keyword', "(display (iff #t 1 2 3))"],
    // evaluated at expansion
    ['inside a macro transformer, four parts',
     "(define-syntax m (lambda (x) (if #t (syntax 1) (syntax 2) (syntax 3))))\n(display (m))"],
    ['inside a macro transformer, no consequent',
     "(define-syntax m (lambda (x) (if #f)))\n(display (m))"],
];
const PRELUDE = {
    'under a renamed keyword': "(import (rename (rnrs) (if iff)))",
};

// DELIBERATELY ABSENT: a program that excludes if from (rnrs).  The
// 2026-09-12 ruling says a name excluded with except may be defined by
// the program and its calls go to that definition.  For the core
// keywords that is not implemented: the compiler recognises them by
// spelling.  On 6ac5df6 a program-defined if half worked by accident
// (a fixed-arity definition was called; a rest-argument one, a use from
// inside an earlier procedure, and an excluded if never defined were
// compiled as the keyword).  Two attempts on 2026-10-21/22 to refuse
// such programs outright each opened new holes and broke programs that
// never wrote an if themselves, because deciding what if means in a
// given scope is the scope-aware keyword resolution of R43 in the
// ledger.  This cell checks the arity of the keyword if only; what an
// excluded if means is R43's, and a row here would pin an accident.

const ACCEPTED = [
    ['CONTROL then and else', "(display (if #f 'a 'b))", 'b'],
    ['CONTROL then only, taken', "(display (if #t 'a))", 'a'],
    ['CONTROL a two-part if ending a loop', "(display (let loop ((i 0)) (if (< i 3) (loop (+ i 1)) 'done)))", 'done'],
    ['CONTROL a three-part if inside a macro transformer',
     "(define-syntax m (lambda (x) (if #f (syntax 1) (syntax 2))))\n(display (m))", '2'],
    ['CONTROL syntax-rules producing a three-part if', "(define-syntax m (syntax-rules () ((_ c) (if c 'y 'n))))\n(display (m #f))", 'n'],
    ['CONTROL a five-element list headed if, quoted, is data', "(display (length '(if 1 2 3 4)))", '5'],
    ['CONTROL a case key spelled if', "(display (case 'if ((if) 'key) (else 'other)))", 'key'],
];
// DELIBERATELY ABSENT: a procedure bound locally to the name if.  On
// 6ac5df6, (let ((if (lambda args (length args)))) (if 1 2 3 4)) prints
// 2: the local binding does not shadow the keyword, which R6RS says it
// should.  That is its own defect (R43 in the ledger), broken before
// this change, and a row for it here would be red for that reason.

test('the self-hosted compiler is present', () => {
    assert.ok(fs.existsSync(snapshot), 'no goeteia.wasm: the stage1 rows cannot run');
});

for (const compiler of COMPILERS) {
    const cname = compiler[0];
    if (cname.startsWith('stage1') && !fs.existsSync(snapshot)) continue;
    for (const [name, body] of REFUSED) {
        test(`[${cname}] ${name} is refused, naming the if`, () => {
            const src = (PRELUDE[name] || '(import (rnrs))') + '\n' + body;
            const r = compile(src, compiler);
            assert.notEqual(r.status, 0, `${name}: the compiler exited 0`);
            assert.equal(r.produced, false, `${name}: the compiler wrote an output file`);
            const keyword = name === 'under a renamed keyword' ? /\b(if|iff)\b/ : /\bif\b/;
            assert.match(r.text, keyword, `${name}: the message does not name the if:\n${r.text}`);
            assert.doesNotMatch(r.text, /\bc[ad]+r\b|incorrect list structure/,
                `${name}: the message names the compiler's own list operations:\n${r.text}`);
        });
    }
    for (const [name, body, want] of ACCEPTED) {
        test(`[${cname}] ${name} compiles and prints ${want}`, () => {
            const r = compile('(import (rnrs))\n' + body, compiler);
            assert.equal(r.status, 0, `${name}: refused:\n${r.text}`);
            assert.equal(r.produced, true, `${name}: no output file`);
            assert.ok(r.ran && r.ran.status === 0, `${name}: did not run cleanly`);
            assert.equal(r.ran.stdout, want, `${name}: printed ${r.ran && r.ran.stdout}`);
        });
    }
}
