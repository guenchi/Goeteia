// The command-line compiler (node rt/compile.mjs, the self-hosted one)
// ends a failed compile with a line that does not read as an internal
// fault when the compiler said what was wrong (ledger R66).
//
// The compiler reports an error by printing it and then trapping
// (unreachable); the driver writes the printed text and then a last line
// of its own.  That line used to be "compile failed: unreachable" -- the
// name of the trap -- whatever the compiler had said above it, so a
// reader who looked at the last line only took a plain "exclude it with
// except" for a crash of the compiler.  When the compiler has printed a
// message, the last line now says the compile failed and points at the
// message; the trap's name stays only when nothing was printed, where it
// is the one fact there is.
//
// Rows, each on both targets (--js too), through the bundled compiler:
//   collide  a program that defines a name it imports
//   reader   a list that is never closed
// Each exits 1, its stderr carries the compiler's own message, and the
// last line of its stderr starts "compile failed" and does not name the
// trap.
//
// BEFORE THE CHANGE the last line is "compile failed: unreachable".
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cli-message-'));

function compile(name, text, js) {
    const src = path.join(dir, `${name}.ss`);
    fs.writeFileSync(src, text);
    const out = path.join(dir, `${name}.${js ? 'js' : 'wasm'}`);
    const args = [path.join(root, 'rt/compile.mjs'), ...(js ? ['--js'] : []), src, out];
    return spawnSync(process.execPath, args, { encoding: 'utf8' });
}
const lastLine = s => s.split('\n').map(l => l.trim()).filter(Boolean).pop() ?? '';

for (const js of [false, true]) {
    const target = js ? 'js' : 'wasm';
    for (const [name, text, said] of [
        ['collide', '(import (rnrs))\n(define (car x) 1)\n(display (car 5))\n', /exclude it with except/],
        ['reader', '(import (rnrs))\n(display (list 1 2\n', /never closed/],
    ]) {
        test(`${name} (${target}): the last line points at the compiler's message`, () => {
            const r = compile(`${name}-${target}`, text, js);
            assert.equal(r.status, 1, `exit status ${r.status}; stderr:\n${r.stderr}`);
            assert.match(r.stderr, said, `the compiler's message is missing:\n${r.stderr}`);
            const last = lastLine(r.stderr);
            assert.match(last, /^compile failed/, `last line: ${last}`);
            assert.doesNotMatch(last, /unreachable/, `the last line names the trap: ${last}`);
        });
    }
}
