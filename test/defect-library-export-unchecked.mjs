// RED ON PURPOSE: a library can export a name nothing defines, and if
// no importer calls it, the whole build succeeds in silence.
//
// test/lib/probe/exported-macro.ss lists `made-in-template` in its
// export clause, and the only definition of that name comes out of a
// macro template, so it is a fresh identifier and not the one exported.
// Refusing that library is CORRECT -- Chez refuses it too, with
// "missing definition for export made-in-template" -- and the defect
// is not that the name is unreachable.  The defect is what happens
// next:
//
//   the name is never called   the build succeeds and prints 4.  A
//                              library with a broken export ships, and
//                              nobody is told.
//   the name is called         refused, with "cannot call: ..." naming
//                              the IMPORTER's file, while the mistake
//                              is in the library's export list.
//
// The second is the loud half and it still points somewhere else.
// The first is silent.
//
// The same check EXISTS on the other export path: a top-level
// (export ...) of an undefined name answers "exported name is not a
// function".  One family, two paths, a check on one of them -- the
// third time that shape turned up in this tree tonight, after
// fx-release!/fx-alloc! and compile-let/compile-%loop.
//
// A FIRST VERSION OF THIS CELL WAS GREEN AND WAS COMMITTED AS RED.
// Its fixture passed the name in as a macro argument, which is never
// renamed -- a fact written down in macro-toplevel-hygiene.ss, two
// files away.  The shape was measured in one form and then written in
// another because the second read better.  Measure the shape you are
// going to commit, not the one that led you to it.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Compile a program that sits in test/, so (probe ...) resolves
// against test/lib/ exactly as the suite resolves it.
function compile(name, src) {
    const f = path.join(root, 'test', `.export-check-${name}.ss`);
    fs.writeFileSync(f, src, 'utf8');
    try {
        execFileSync(path.join(root, 'bin/goeteiac'), [f, `${f}.wasm`],
                     { cwd: root, stdio: 'pipe' });
        return null;
    } catch (e) {
        return `${e.stdout || ''}${e.stderr || ''}`;
    } finally {
        fs.rmSync(f, { force: true });
        fs.rmSync(`${f}.wasm`, { force: true });
    }
}

test('a library whose export names nothing is refused even when unused', () => {
    const why = compile('unused',
        '(import (rnrs) (probe exported-macro))\n(display (written-out 2))\n');
    assert.ok(why !== null,
              'the build succeeded: a library with a broken export shipped in silence');
});

test('and the refusal names the library, not the importer', () => {
    const why = compile('used',
        '(import (rnrs) (probe exported-macro))\n(display (made-in-template 2))\n');
    assert.ok(why !== null, 'calling it must still be refused');
    assert.match(why, /export/,
                 'the message must point at the export list; "cannot call" names the ' +
                 'importer\'s file while the mistake is in the library');
});

test('CONTROL a library whose exports are all defined still builds', () => {
    // Without this, refusing every library would satisfy both reds.
    const why = compile('control',
        '(import (rnrs) (math base))\n(display 1)\n');
    assert.equal(why, null, `a well-formed library must still load:\n${why}`);
});
