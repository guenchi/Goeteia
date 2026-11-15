// A direct call of a comparison with fewer than two arguments, or of not
// with other than one, is refused at compile time with a message that
// names the procedure as the program wrote it (ledger R20, batch M53).
//
// The comparisons take two or more arguments and not takes one.  A
// direct call with three or more compiles to the n-ary procedure; one
// with a single argument is a wrong count, refused where it is written,
// as a wrong count for a primitive is.  Before this batch (< 1) was
// "wrong argument count for primitive: <", (char<? #\a) a call of a
// two-parameter procedure that trapped or answered nonsense at run
// time, and (not #f 1) compiled and answered (not #f): the expander
// read the first operand and dropped the rest.
//
// FIVE COMPILERS, as in test/if-arity-is-checked.mjs: the Chez-hosted
// compiler to wasm and to JS, and the self-hosted one (rt/compile.mjs
// with goeteia.wasm) to wasm, to JS and unoptimized.
//
// WHAT A REFUSAL ROW ASKS: the compiler exits unsuccessfully, writes no
// output file, and its message -- with this cell's temporary paths
// removed -- says "<name> takes", where <name> is the spelling the
// program wrote (so a renamed import is named as renamed).
//
// WHAT A CONTROL ROW ASKS: the program compiles AND runs AND prints what
// it should.  The controls are what a check keyed on the spelling alone
// would break: a local binding spelled <, a program that excludes < and
// defines its own, not and < inside quoted data, and a case key spelled
// not.
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
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-counts-'));
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

// [label, the name the message must give, program]
const REFUSED = [
    ['not with no argument', 'not', '(import (rnrs))\n(display (not))'],
    ['not with two arguments', 'not', '(import (rnrs))\n(display (not #f 1))'],
    ['< with one argument (a primitive)', '<', '(import (rnrs))\n(display (< 1))'],
    ['char<? with one argument (a prelude procedure)', 'char<?',
     '(import (rnrs))\n(display (char<? #\\a))'],
    ['a renamed < with one argument', 'lt',
     '(import (rename (rnrs) (< lt)))\n(display (lt 1))'],
];

// [label, program, what it prints]
const CONTROLS = [
    ['not with one argument', '(import (rnrs))\n(display (not #f))', '#t'],
    ['< with two arguments', '(import (rnrs))\n(display (< 1 2))', '#t'],
    ['< with three arguments', '(import (rnrs))\n(display (< 1 2 3))', '#t'],
    ['a local binding spelled <, called with one argument',
     '(import (rnrs))\n(display (let ((< (lambda (x) (* x 10)))) (< 4)))', '40'],
    ['a program that excludes < and defines its own of one parameter',
     '(import (except (rnrs) <))\n(define (< x) (+ x 1))\n(display (< 4))', '5'],
    ['not and < inside quoted data',
     "(import (rnrs))\n(display (list '(not) '(not 1 2) '(< 1)))", '((not) (not 1 2) (< 1))'],
    ['a case key spelled not',
     "(import (rnrs))\n(display (case 'not ((not) 1) (else 2)))", '1'],
];

for (const compiler of COMPILERS) {
    const [label] = compiler;
    for (const [name, who, src] of REFUSED) {
        test(`${label}: ${name} is refused`, () => {
            const r = compile(src, compiler);
            assert.notEqual(r.status, 0, `compiled; output: ${r.text}`);
            assert.equal(r.produced, false, 'an output file was written');
            assert.ok(r.text.includes(`${who} takes`),
                      `the message does not name ${who}: ${r.text}`);
        });
    }
    for (const [name, src, want] of CONTROLS) {
        test(`${label}: ${name} compiles and runs`, () => {
            const r = compile(src, compiler);
            assert.equal(r.status, 0, `refused: ${r.text}`);
            assert.ok(r.ran, 'did not run');
            assert.equal(r.ran.status, 0, `exited ${r.ran.status}`);
            assert.equal(r.ran.stdout, want);
        });
    }
}
