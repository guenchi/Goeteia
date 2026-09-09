// Hygiene is the thing the macro-toplevel fix must not spend.
//
// test/defect-macro-toplevel-{var,const}-mark.ss ask for a macro's own
// expansion to be able to read a top-level value definition it made.
// ⭐ The obvious way to make them green is to stop marking those names
// -- key *vars* by the stripped symbol.  That also makes a name a
// macro introduces visible to code the user wrote, which is precisely
// what hygiene forbids, and no cell over there would notice.
//
// So this file asserts the refusal.  It has to be a .mjs: the program
// below must FAIL to compile, and a compile error takes a whole .ss
// file's verdict with it, so it cannot share a file with anything.
//
// Reference: Chez refuses the same program ("variable mc is not
// bound").  This compiler refuses it at compile time rather than at
// run time, which for a whole-program compiler is the earlier and
// better of the two places, and either way the program does not run.
//
// ⚠️ The control below is the half that keeps this from being
// satisfied by a compiler that refuses everything.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-hygiene-'));

// Returns the compiler's combined output on refusal, or null if it
// accepted the program.
function refusal(src) {
    const f = path.join(dir, `${Math.random().toString(36).slice(2)}.ss`);
    fs.writeFileSync(f, src, 'utf8');
    try {
        execFileSync(path.join(root, 'bin/goeteiac'), [f, `${f}.wasm`],
                     { cwd: root, stdio: 'pipe' });
        return null;
    } catch (e) {
        return `${e.stdout || ''}${e.stderr || ''}`;
    }
}

test('a user-written reference does not see a name a macro introduced', () => {
    const why = refusal(`(import (rnrs))
(define-syntax m (syntax-rules () ((_) (define mc 1))))
(m)
(display mc)`);
    assert.ok(why !== null,
              'the program compiled: a macro-introduced name leaked to user code');
    assert.match(why, /unbound variable/,
                 'refused, but not as an unbound variable -- read the message ' +
                 'before assuming this still tests hygiene');
});

test('the same program with the name passed in as an argument compiles', () => {
    // ⭐ The control.  Without it, a compiler that refused every
    // program would pass the cell above.  The only difference here is
    // that the name came from the call site, so it was never marked.
    const why = refusal(`(import (rnrs))
(define-syntax m (syntax-rules () ((_ n) (define n 1))))
(m mc)
(display mc)`);
    assert.equal(why, null,
                 `a name given as a macro argument must still work:\n${why}`);
});

test.after(() => fs.rmSync(dir, { recursive: true, force: true }));
