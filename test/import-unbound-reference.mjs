// A reference to a name the import clause does not bring in is an
// unbound-variable error at compile time, in call and value position,
// judged per scope -- the program against its clause, a library body
// against its own.  The rows read the compiler's message for an
// excluded name and for a name outside an only list; the controls are
// the references that must keep compiling: a name the clause brings
// in, a primitive no library exports, a renamed import.  This file was
// red as defect-unbound-reference-not-checked while the check was
// withdrawn (its first version turned 179 cells red for five causes,
// all fixed before it was turned on) and is green since 60ac2bd.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

function compileError(src) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-unbound-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, src + '\n');
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 120000 });
    const produced = fs.existsSync(wasm);
    fs.rmSync(dir, { recursive: true, force: true });
    return produced ? null : ((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop();
}

const rows = [
    ['a reference to an excluded name',   '(import (except (rnrs) car))\n(display (car (list 1)))',   /unbound variable: car/],
    ['a reference outside an only list',  '(import (only (rnrs) display))\n(display (car (list 1)))', /unbound variable: car/],
];

for (const [title, src, want] of rows) {
    test(`unbound: ${title}`, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
        const err = compileError(src);
        assert.ok(err !== null, 'the program compiled; the reference should be unbound');
        assert.match(err, want);
    });
}

test('control: bound names, the implementation allowance and a renamed import compile', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    assert.equal(compileError('(import (only (rnrs) display))\n(display 1)'), null);
    assert.equal(compileError('(import (rnrs))\n(display (%mem-size))'), null);
    assert.equal(compileError('(import (rename (rnrs) (display show)))\n(show 7)'), null);
});
