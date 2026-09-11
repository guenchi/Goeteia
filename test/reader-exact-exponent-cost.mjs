// The reader must not build an unbounded exact integer for a numeric
// literal whose exponent's VALUE is large.  `#e1e999999` is a dozen
// characters; read exactly, it is 10^999999, and the construction
// `(* whole (expt 10 scale))` in the number path never returns.
// string->number already answers #f for that spelling, but `read`
// from a port reaches the exact build, so any runtime path that reads
// external text -- and the compiler reading source -- can be hung by
// one short token.  This runs the reader in a SUBPROCESS under a hard
// timeout: a build with the bound removed must time out (exit 124),
// which is the shape a hang has to be given so it fails rather than
// stalls the suite.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

function readsInTime(literal) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-readcost-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, `(import (rnrs))\n(display (read (open-input-string ${JSON.stringify(literal)})))\n`);
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 60000 });
    if (c.error || !fs.existsSync(wasm)) { fs.rmSync(dir, { recursive: true, force: true }); return { built: false, err: (c.stderr || '').trim().split('\n').pop() }; }
    const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), wasm], { encoding: 'utf8', timeout: 8000 });
    fs.rmSync(dir, { recursive: true, force: true });
    return { built: true, timedOut: !!r.error, out: ((r.stdout || '') + '').trim() };
}

test('reading a numeric literal with a huge exact exponent returns rather than hangs', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    const r = readsInTime('#e1e999999');
    assert.ok(r.built, `the fixture did not compile: ${r.err}`);
    assert.ok(!r.timedOut, 'reading #e1e999999 did not return within 8s -- the reader is building 10^999999');
    // R6RS leaves the answer open for an out-of-range exact; #f (reject)
    // or a bounded refusal are both fine -- what is not fine is a hang
    assert.notEqual(r.out, '', 'the reader returned nothing (hang or crash), not a value');
});

test('control: a small exact exponent still reads to the exact integer', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    const r = readsInTime('#e1e9');
    assert.ok(r.built && !r.timedOut, 'the small case must read quickly');
    assert.equal(r.out, '1000000000', 'a bounded exact exponent must still build its integer');
});

function numberInTime(literal) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-numcost-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, `(import (rnrs))\n(display (string->number ${JSON.stringify(literal)}))\n`);
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 60000 });
    if (c.error || !fs.existsSync(wasm)) { fs.rmSync(dir, { recursive: true, force: true }); return { built: false }; }
    const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), wasm], { encoding: 'utf8', timeout: 8000 });
    fs.rmSync(dir, { recursive: true, force: true });
    return { built: true, timedOut: !!r.error, out: ((r.stdout || '') + '').trim() };
}

// string->number shares %body->number with the reader and needs no #
// prefix: the plain inexact spelling builds the exact magnitude before
// converting, so "1e999999" constructs 10^999999 on its way to a
// flonum.  This is the caller that reaches user-typed text.
for (const lit of ['1e999999', '1e-999999']) {
    test(`string->number ${lit} returns rather than hangs`, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH)'); return; }
        const r = numberInTime(lit);
        assert.ok(r.built && !r.timedOut, `string->number ${lit} did not return within 8s -- the parser is building the magnitude`);
    });
}

test('control: string->number 1.5 still works', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH)'); return; }
    const r = numberInTime('1.5');
    assert.ok(r.built && !r.timedOut && r.out === '1.5', `1.5 must parse: ${JSON.stringify(r)}`);
});
