// The diagnostics a user actually meets: what rt/compile.mjs prints
// when the self-hosted compiler (goeteia.wasm) refuses a source file.
// Both the exit status and the text on stderr are part of the
// contract -- a build script reads the first, a human reads the
// second.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import url from 'node:url';

const here = path.dirname(url.fileURLToPath(import.meta.url));
const compileMjs = path.join(here, '../rt/compile.mjs');
const compilerWasm = path.join(here, '../goeteia.wasm');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-readerdiag-'));

// compile source with the self-hosted compiler; return { status, stderr }
function compile(name, source) {
    const src = path.join(tmp, name);
    fs.writeFileSync(src, source);
    try {
        execFileSync(process.execPath,
                     [compileMjs, compilerWasm, src, path.join(tmp, 'out.wasm')],
                     { stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
        return { status: e.status, stderr: String(e.stderr) };
    }
    return { status: 0, stderr: '' };
}

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

test('an exponent literal is named as such, not just "unbound"', () => {
    const { status, stderr } = compile('exponent.ss',
        ';; expect: 0\n(define eps 1e-3)\n(display eps)\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /unbound variable/);
    assert.match(stderr, /exponent literals are not supported by this reader/);
    assert.match(stderr, /write the constant out/);
});

test('set! of an exponent literal carries the same hint', () => {
    const { status, stderr } = compile('exponent-set.ss',
        ';; expect: 0\n(set! 2.5E+7 1)\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /exponent literals are not supported by this reader/);
});

test('an ordinary name that merely contains an e gets no exponent hint', () => {
    // the negative control: elf-3 is unbound, and saying anything
    // about exponents here would be a lie that costs the reader time
    const { status, stderr } = compile('ordinary.ss',
        ';; expect: 0\n(display elf-3)\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /unbound variable/);
    assert.doesNotMatch(stderr, /exponent/);
});

test('an unclosed list names where it opened', () => {
    const { status, stderr } = compile('unclosed.ss',
        ';; expect: 0\n(define (f x)\n  (+ x\n     1)\n(display (f 1))\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /list opened at line \d+ column \d+ never closed/);
    // the column is a real column of the offending line, not a
    // stream-wide character offset: (define starts the line
    assert.match(stderr, /column 1 never closed/);
});

test('a close paren with nothing open is reported, not looped on', () => {
    // before positions existed this fell through to the atom reader,
    // which consumed nothing and left the driver spinning
    const { status, stderr } = compile('stray.ss',
        ';; expect: 0\n(display 1))\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /unexpected \) at line \d+ column 12/);
});

test('an unclosed string names its open quote', () => {
    const { status, stderr } = compile('unstring.ss',
        ';; expect: 0\n(display "hello)\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /string opened at line \d+ column 10 never closed/);
});
