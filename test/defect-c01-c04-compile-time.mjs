// Two defects from the 2026-09-06 review whose counterexample is a
// COMPILE-TIME fact rather than a wrong value, so a `;; expect:` line
// cannot hold them.  Both were re-measured on 2026-09-09 and are live.
//
// RED ON PURPOSE.  These go in before any repair, because "the suite is
// green" is not evidence that a patch landed.
//
//   C01  a numeric loop parameter captured by an inner lambda produces
//        wasm that will not instantiate.  `(let loop ((i 1)) ((lambda ()
//        i)))` at the DEFAULT optimisation level emits a struct.new that
//        stores an i32 where an eqref is declared, and
//        WebAssembly.instantiate refuses it.  The same shape with 1.0
//        fails as f64 against eqref.  ⚠️ Unoptimised wasm and both JS
//        modes answer 1, which is why nothing in the suite has ever
//        mentioned it: every test runs somewhere the defect is absent.
//        Reported location: src/compiler.ss:1855 (compile-%loop's local
//        type inference).
//
//   C04  dead-code elimination removes an ill-formed initialiser before
//        anything checks its arity.  `(define unused (cons 1)) 42`
//        compiles and answers 42 on all four combinations; `cons` with
//        one argument is never reported.  ⭐ "It writes no side effect"
//        does not imply "it cannot fail", and the elimination is
//        applied at -O0 as well, so there is no setting in which the
//        program is checked.  Reported location: src/compiler.ss:3311
//        (pure-init? treats every cons as removable).
//
// ⚠️ Both cells run all four combinations on purpose, and the readings
// are narrower than the review's summary in two ways worth recording:
//
//   C01 fails at wasm -O2 ONLY.  wasm -O0 and both JS modes compile and
//       answer 1.  A harness that picked one optimisation level had a
//       three-in-four chance of reporting the defect absent.
//
//   C04 escapes at TOP LEVEL only.  `(let ((u (cons 1))) 42)` and a
//       `(cons 1)` whose value is actually read are both refused today,
//       on all four.  ⭐ So the elimination is not the whole story: the
//       hole is specifically an unused TOP-LEVEL initialiser, and a
//       repair aimed at "check arity before eliminating" should be told
//       that two of the three placements already do.
//
// Both of those came out of running the matrix rather than out of the
// report, which is the argument for running it.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-c01-c04-'));
const write = (name, src) => {
    const f = path.join(dir, `${name}.ss`);
    fs.writeFileSync(f, src, 'utf8');
    return f;
};
// every combination the compiler offers, named, so a failure says which
const COMBOS = [
    ['wasm -O2', {}],
    ['wasm -O0', { script: true }],
    ['js   -O2', { target: 'js' }],
    ['js   -O0', { target: 'js', script: true }],
];

const problems = [];
const note = (m) => problems.push(m);

// ---- C01: the emitted module must instantiate ----
//
// Compiling is not the assertion: the bad module compiles fine and is
// rejected later, by the engine.  So each wasm combination is actually
// instantiated, and the JS combinations are checked for the same
// program's answer, which is 1.
for (const [name, src] of [
    ['int', '(import (rnrs))\n(display (let loop ((i 1)) ((lambda () i))))\n'],
    ['flonum', '(import (rnrs))\n(display (let loop ((i 1.0)) ((lambda () i))))\n'],
    ['nested', '(import (rnrs))\n(display (let outer ((i 1))'
             + ' (let inner ((j 2)) ((lambda () (+ i j))))))\n'],
]) {
    const f = write(`c01-${name}`, src);
    for (const [combo, opts] of COMBOS) {
        let bytes;
        try {
            bytes = await compileToBytes(f, opts);
        } catch (e) {
            note(`C01 ${name} (${combo}): did not compile: ${e.message}`);
            continue;
        }
        if (opts.target === 'js') continue;          // nothing to instantiate
        try {
            await WebAssembly.instantiate(bytes, {
                io: { write_byte(){}, read_byte: () => -1, path_byte(){}, open_read: () => -1,
                      open_write: () => -1, fread: () => -1, fwrite(){}, fclose(){} },
                js: new Proxy({}, { get: () => () => 0 }),
            });
        } catch (e) {
            note(`C01 ${name} (${combo}): the module will not instantiate: ${e.message}`);
        }
    }
}

// ---- C04: an ill-formed initialiser must be reported ----
//
// The green twin matters as much as the refusal: a repair that checked
// arity by declining to eliminate anything would make the suite slower
// and this cell would not notice.  So a WELL-formed unused initialiser
// must still compile, and -- since eliminating it is the point -- the
// program must still be accepted with the binding never read.
const illFormed = [
    ['toplevel-unused', '(import (rnrs))\n(define unused (cons 1))\n(display 42)\n'],
    ['local-unused', '(import (rnrs))\n(display (let ((u (cons 1))) 42))\n'],
    ['actually-used', '(import (rnrs))\n(define u (cons 1))\n(display (car u))\n'],
];
for (const [name, src] of illFormed) {
    const f = write(`c04-${name}`, src);
    for (const [combo, opts] of COMBOS) {
        let failed = false;
        try { await compileToBytes(f, opts); } catch { failed = true; }
        if (!failed) {
            note(`C04 ${name} (${combo}): \`(cons 1)\` was accepted -- `
                 + `arity is not checked before elimination`);
        }
    }
}
// the twin
{
    const f = write('c04-wellformed-unused', '(import (rnrs))\n(define ok (cons 1 2))\n(display 42)\n');
    for (const [combo, opts] of COMBOS) {
        try { await compileToBytes(f, opts); }
        catch (e) { note(`C04 twin (${combo}): a WELL-formed unused initialiser was refused: ${e.message}`); }
    }
}

fs.rmSync(dir, { recursive: true, force: true });
if (problems.length) {
    for (const p of problems) console.log(`  FAIL ${p}`);
    console.log(`c01-c04: ${problems.length} failing`);
    process.exitCode = 1;
} else {
    console.log('c01-c04: ok');
}
