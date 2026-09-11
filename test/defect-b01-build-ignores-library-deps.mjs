// REGRESSION GUARD (written as a red witness at 23f6696; green since).
// The defect as it then was: build.sh decides whether a page needs
// recompiling by comparing the page's own source with its .wasm, and
// nothing else.
//
//     [ "$src" -nt "$wasm" ] || continue
//
// -> A library the page imports can be newer than the artifact and the
// page is skipped.  The dev server runs this on every save, so editing
// a shared library and reloading serves the old picture -- and reloads
// keep serving it, because the timestamp that decides never moves.
//
// The freshness of a derived artifact is checked against ONE of its
// inputs rather than against its dependency closure.  The compiler
// snapshot and the prelude are inputs too, and are not compared
// either; this cell tests the library case because it is the one a
// person hits while working.
//
// The failure is a stale picture, not an error.  Nothing in the
// output says "this is the previous build", so the natural reading is
// that the edit did not do what the author thought.
//
// The real build.sh is copied into a sandbox and run there, rather
// than reimplemented here.  Its DIR comes from its own path, so a copy
// walks the sandbox -- which means the cell exercises the script as
// shipped, and a change to that one line moves this cell.  A
// reimplementation would only ever agree with itself.
//
// The controls are the two cases that must keep working: a page whose
// own source is newer IS rebuilt, and a page newer than nothing is
// left alone.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// lib/ is a REAL directory here, holding one symlink per library.
// A first version symlinked lib/ itself and then created the fixture
// library inside it -- which is a hole straight into the repository,
// and it created lib/sandbox/ in the working tree before anyone
// noticed.  A symlinked directory in a fixture is not a copy of the
// tree; it IS the tree, and everything the test writes lands there.
function sandbox() {
    const d = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-b01-'));
    for (const n of ['bin', 'rt', 'src', 'goeteia.wasm'])
        fs.symlinkSync(path.join(root, n), path.join(d, n));
    fs.mkdirSync(path.join(d, 'lib'));
    for (const n of fs.readdirSync(path.join(root, 'lib')))
        fs.symlinkSync(path.join(root, 'lib', n), path.join(d, 'lib', n));
    fs.copyFileSync(path.join(root, 'build.sh'), path.join(d, 'build.sh'));
    return d;
}

// a page that imports a library, both inside the sandbox
function makePage(d) {
    fs.mkdirSync(path.join(d, 'lib', 'sb'), { recursive: true });
    fs.writeFileSync(path.join(d, 'lib', 'sb', 'shared.ss'),
        '(library (sb shared)\n  (export answer)\n  (import (rnrs))\n' +
        '  (define (answer) 1))\n', 'utf8');
    // A second library the page does NOT import.  Without it, "rebuild
    // when any library changed" satisfies every other assertion in
    // this file, and that answer degrades the dependency closure into
    // the whole tree: on a dev server it turns "save and rebuild" into
    // "save and rebuild everything".  Over-repair is invisible to a
    // cell that only ever asks whether a rebuild happened.
    fs.writeFileSync(path.join(d, 'lib', 'sb', 'unrelated.ss'),
        '(library (sb unrelated)\n  (export unused)\n  (import (rnrs))\n' +
        '  (define (unused) 1))\n', 'utf8');
    const page = path.join(d, 'page.ss');
    fs.writeFileSync(page, ';; expect: 1\n(import (rnrs) (sb shared))\n(display (answer))\n', 'utf8');
    return page;
}

function build(d) {
    // build.sh runs under `set -e`, so a failed compile aborts it.  
    // Return stdout AND stderr: a cell that only read stdout would see
    // "no compile line" and report the defect under test when what
    // actually happened is that the fixture did not compile.
    try {
        const out = execFileSync('sh', [path.join(d, 'build.sh')],
                                 { cwd: d, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
        return out;
    } catch (e) {
        return `${e.stdout || ''}${e.stderr || ''}`;
    }
}

function ageBy(file, seconds) {
    const t = Date.now() / 1000 - seconds;
    fs.utimesSync(file, t, t);
}

test('CONTROL a page newer than its artifact is rebuilt', () => {
    const d = sandbox();
    try {
        const page = makePage(d);
        const wasm = page.replace(/\.ss$/, '.wasm');
        fs.writeFileSync(wasm, '');
        ageBy(wasm, 60);
        assert.match(build(d), /compile/, 'the page was not rebuilt');
    } finally { fs.rmSync(d, { recursive: true, force: true }); }
});

test('CONTROL a page older than its artifact is left alone', () => {
    const d = sandbox();
    try {
        const page = makePage(d);
        const wasm = page.replace(/\.ss$/, '.wasm');
        fs.writeFileSync(wasm, '');
        ageBy(page, 60);
        assert.doesNotMatch(build(d), /compile/, 'the page was rebuilt for no reason');
    } finally { fs.rmSync(d, { recursive: true, force: true }); }
});

test('a page whose imported library is newer is rebuilt', () => {
    const d = sandbox();
    try {
        const page = makePage(d);
        const wasm = page.replace(/\.ss$/, '.wasm');
        fs.writeFileSync(wasm, '');
        ageBy(page, 120);
        ageBy(wasm, 60);            // artifact newer than the page ...
        const lib = path.join(d, 'lib', 'sb', 'shared.ss');
        fs.writeFileSync(lib, fs.readFileSync(lib, 'utf8').replace('1', '2'));
        // ... and the library newer than the artifact
        assert.match(build(d), /compile/,
                     'the library changed and the page kept its old artifact');
    } finally { fs.rmSync(d, { recursive: true, force: true }); }
});

test('a page is NOT rebuilt when a library it does not import changes', () => {
    const d = sandbox();
    try {
        const page = makePage(d);
        const wasm = page.replace(/\.ss$/, '.wasm');
        fs.writeFileSync(wasm, '');
        ageBy(page, 120);
        // The library the page DOES import has to be aged too.  It was
        // written moments ago by makePage, so leaving it alone makes it
        // newer than the artifact and the rebuild is then correct --
        // this assertion would fail against a correct implementation,
        // for a reason that has nothing to do with the unrelated file.
        ageBy(path.join(d, 'lib', 'sb', 'shared.ss'), 120);
        ageBy(wasm, 60);
        const other = path.join(d, 'lib', 'sb', 'unrelated.ss');
        fs.writeFileSync(other, fs.readFileSync(other, 'utf8').replace('1', '2'));
        assert.doesNotMatch(build(d), /compile/,
                            'a library the page never imports forced a rebuild');
    } finally { fs.rmSync(d, { recursive: true, force: true }); }
});

test('a transitive dependency counts', () => {
    const d = sandbox();
    try {
        const page = makePage(d);
        // shared imports leaf, so the page reaches leaf through it
        fs.writeFileSync(path.join(d, 'lib', 'sb', 'leaf.ss'),
            '(library (sb leaf)\n  (export base)\n  (import (rnrs))\n' +
            '  (define (base) 1))\n', 'utf8');
        fs.writeFileSync(path.join(d, 'lib', 'sb', 'shared.ss'),
            '(library (sb shared)\n  (export answer)\n' +
            '  (import (rnrs) (sb leaf))\n' +
            '  (define (answer) (base)))\n', 'utf8');
        const wasm = page.replace(/\.ss$/, '.wasm');
        fs.writeFileSync(wasm, '');
        ageBy(page, 120);
        ageBy(path.join(d, 'lib', 'sb', 'shared.ss'), 120);
        ageBy(wasm, 60);
        const leaf = path.join(d, 'lib', 'sb', 'leaf.ss');
        fs.writeFileSync(leaf, fs.readFileSync(leaf, 'utf8').replace('1', '2'));
        assert.match(build(d), /compile/,
                     'a library reached through another was not counted');
    } finally { fs.rmSync(d, { recursive: true, force: true }); }
});
