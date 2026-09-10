// The prelude must not notice what a program calls its own functions.
// For every name in the compiler's `primitives` list -- parsed from
// src/compiler.ss at test time, so a new primitive is a new row -- the
// program defines that name at the top level and then displays 1.
// Predicates are redefined to answer #f, everything else to answer a
// symbol, because the two shapes break different walks: a null? that
// answers #f never stops a list walk, a cdr that answers a symbol ends
// one in a cast.  If the prelude's own references resolved where they
// were written, no definition could reach them and every row prints 1.
//
// Baseline on 1041cf3 (compiler 6cc5d643), in a pinned worktree: eleven
// rows red -- null? cdr eq? + < fixnum? and five internals (%record?
// %record %record-ref %make-vector %write-byte).  A census with BOTH
// shapes for every name finds four more (flonum? %bignum? %complex?
// %ratio?, which break only when redefined to answer a symbol); one
// shape per row keeps the file at 136 rows and the four are covered
// by the same fix.  The rest print 1 today because (display 1) happens
// not to exercise them, which is why the row is "prints 1" and not
// "the prelude's calls resolve to the prelude": the second is what the
// fix establishes, the first is what a program can observe.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

function primitives() {
    const src = fs.readFileSync(path.join(root, 'src/compiler.ss'), 'utf8');
    const i = src.indexOf('(define primitives');
    const j = src.indexOf('\n(define ', i + 10);
    assert.ok(i > 0 && j > i, 'the primitives list was not found in src/compiler.ss');
    const block = src.slice(i, j).replace(/;.*/g, '');
    const names = [...new Set(block.match(/[^\s()']+/g).filter(t => t !== 'define' && t !== 'primitives'))];
    assert.ok(names.length > 100, `only ${names.length} primitives parsed; the list's shape changed`);
    return names;
}

function answerAfterRedefining(name) {
    const body = name.endsWith('?') ? '#f' : '(quote mine)';
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-prim-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, `(import (rnrs))\n(define (${name} . args) ${body})\n(display 1)\n`);
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 120000 });
    if (!fs.existsSync(wasm)) { fs.rmSync(dir, { recursive: true, force: true }); return `COMPILE-ERR: ${(c.stderr || '').trim().split('\n').pop()}`; }
    const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), wasm], { encoding: 'utf8', timeout: 20000 });
    fs.rmSync(dir, { recursive: true, force: true });
    if (r.error) return `RUN-TIMEOUT`;
    return ((r.stdout || '') + (r.stderr || '')).trim().split('\n')[0];
}

if (!chez) {
    test('prelude survives primitive redefinition', () => { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and no reading was taken)'); });
} else {
    for (const name of primitives()) {
        test(`the prelude survives a top-level definition of ${name}`, () => {
            assert.equal(answerAfterRedefining(name), '1');
        });
    }
}
