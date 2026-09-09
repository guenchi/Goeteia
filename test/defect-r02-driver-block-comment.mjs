// RED ON PURPOSE: the host-side driver reads a source file to the end
// without noticing that a block comment was never closed.
//
//   (display 1) #| never closed
//
// compiles, runs, and prints 1.  Chez refuses the same file
// ("unexpected end-of-file reading block comment").  ⚠️ What is lost
// is not the comment -- it is everything after the `#|`, which the
// author believed was code.  A file truncated mid-edit, or one whose
// closing `|#` was deleted, becomes a shorter program that still
// builds.
//
// ⭐ TWO readers, wrong in opposite directions.  The prelude's `read`
// -- the one a compiled program calls -- refuses this correctly, and
// has the opposite defect on dotted tails, which it accepts and
// silently truncates.  See test/defect-p04-reader-dotted.ss.  Neither
// tells you anything about the other, and a fix to one is not a fix to
// the other; they were measured separately and must stay that way.
//
// This is a .mjs because the assertion is that a program is REFUSED,
// and run-tests.sh reads a .ss file's first line as its expected
// output -- a refusal there is indistinguishable from a broken test.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-r02-'));

function compiles(src) {
    const f = path.join(dir, `${Math.random().toString(36).slice(2)}.ss`);
    fs.writeFileSync(f, src, 'utf8');
    try {
        execFileSync(path.join(root, 'bin/goeteiac'), [f, `${f}.wasm`],
                     { cwd: root, stdio: 'pipe' });
        return true;
    } catch {
        return false;
    }
}

test('a block comment that is never closed is refused', () => {
    assert.equal(compiles('(import (rnrs))\n(display 1) #| never closed\n'), false,
                 'the file compiled: everything after #| was dropped in silence');
});

test('a block comment left open inside a list is refused', () => {
    // ⭐ Already green, and it localises the defect: this one is
    // refused because the LIST is unterminated, not because the
    // comment is.  Something else was still pending, so the reader had
    // a reason to complain.  ⇒ The hole is exactly the case where
    // nothing else is open, which is also the common one -- a comment
    // at the end of a file.
    assert.equal(compiles('(import (rnrs))\n(display (list 1 #| never closed\n'), false);
});

test('a closed block comment still compiles', () => {
    // ⭐ The control, and it has to be here: "refuse the file" is
    // satisfied by refusing every file, and the reds above cannot tell
    // the difference.
    assert.equal(compiles('(import (rnrs))\n#| fine |#\n(display 1)\n'), true);
});

test('a datum comment still compiles', () => {
    assert.equal(compiles('(import (rnrs))\n(display #;(dropped) 1)\n'), true);
});

test.after(() => fs.rmSync(dir, { recursive: true, force: true }));
