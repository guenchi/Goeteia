// The identity of a TOP-LEVEL procedure is not the same on the two
// targets, and this file exists because nothing else can say so.
//
// A .ss fixture cannot: run-tests.sh reads ONE `;; expect:` line from
// the first line of the file and holds all four runs to it (stage0
// wasm, stage1 wasm, JS, and the cross-host byte comparisons).  There
// is no way to write "wasm answers this, JS answers that" in that
// grammar -- which is why this divergence had no test, and why
// test/trig.ss had to reach for a textual check instead of `eq?`.
// The precedent for stepping out to .mjs is that same file's
// companion, test/trig-single-supply.mjs.
//
// The divergence itself is deliberate and documented in
// src/js-backend.ss: the JS emitter hands back one stable function
// object for every reference to a top-level name, while the wasm
// emitter builds a fresh closure struct at each reference site.  What
// was NOT true was the sentence that used to follow it -- that the
// suite pinned these corners down as unobservable.  Both expressions
// below are ordinary, and until this file existed neither was run.
//
// So this is a CHARACTERISATION test, not a wish: it records what each
// target answers today.  If a change makes them agree, this file goes
// red, and that red means "go update the note in src/js-backend.ss",
// not "a bug appeared".
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-proc-identity-'));

// Each case names both answers, so neither target can drift quietly:
// asserting only one of them would leave the other free to change.
async function bothAnswer(name, source, wantWasm, wantJs) {
    const sourceFile = path.join(dir, `${name}.ss`);
    const jsFile = path.join(dir, `${name}.mjs`);
    fs.writeFileSync(sourceFile, source, 'utf8');
    const wasm = await compileToBytes(sourceFile, { script: true });
    fs.writeFileSync(
        jsFile,
        await compileToBytes(sourceFile, { script: true, target: 'js' }));
    const w = await runModule(wasm);
    const j = await runJsModule(jsFile);
    assert.equal(w.text.trim(), wantWasm, `${name}: wasm`);
    assert.equal(j.text.trim(), wantJs, `${name}: js`);
}

try {
    // A top-level name used as a value twice: the wasm target wraps it
    // afresh each time, so the two references are not eq?.
    await bothAnswer(
        'eq-top-level',
        '(define (f x) x)\n(display (eq? f f))\n(newline)\n',
        '#f', '#t');

    // The same difference reached through a container that is defined
    // by eq? -- this is the shape a program actually hits, and it is
    // why "unobservable" was the wrong word.
    await bothAnswer(
        'eq-hashtable-top-level',
        '(define (f x) x)\n(define h (make-eq-hashtable))\n' +
        '(hashtable-set! h f 42)\n' +
        '(display (hashtable-ref h f (quote missing)))\n(newline)\n',
        'missing', '42');

    // The should-AGREE half.  Without it, "the targets differ about
    // procedure identity" would read as true of every procedure, and a
    // change that broke identity for LOCAL procedures too would leave
    // the two cases above still green.  A local binding is one closure
    // on both targets.
    await bothAnswer(
        'eq-local-procedure',
        '(let ((g (lambda (x) x))) (display (eq? g g)))\n(newline)\n',
        '#t', '#t');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
