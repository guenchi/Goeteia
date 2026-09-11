// RED ON PURPOSE: a reference to a name the import clause does not
// bring in should be an unbound-variable error at compile time, in
// call and value position, judged per scope -- the program against
// its clause, a library body against its own.  Today the reference
// resolves anyway: except and only constrain what may be DEFINED (the
// refusal half of the import rule, which is in) but not what may be
// REFERENCED.  A first implementation of the check turned 179 cells
// red for five distinct reasons -- export declarations read as
// references, internal definitions not bound, inline libraries'
// imports never reaching the importing scope's map, builtins such as
// apply and call/cc missing from the manifest, and libraries reaching
// prelude internals -- and was withdrawn; it returns as its own step
// with those designed first.  The controls below must stay green
// throughout: a name the clause brings in, a primitive no library
// exports, a renamed import.
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
    ['a reference to an excluded name',   '(import (except (rnrs) car))\n(display (car (list 1)))',   /car is not bound/],
    ['a reference outside an only list',  '(import (only (rnrs) display))\n(display (car (list 1)))', /car is not bound/],
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
