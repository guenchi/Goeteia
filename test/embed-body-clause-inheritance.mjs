// An embed body (conjure, define-wasm-js, ...) written WITHOUT an
// import clause must be judged against the enclosing program's import
// map: a name the program imports is accepted, a name it does not is
// refused.  Today a clause-less body is not judged at all -- with no
// clause there is no marker, nothing is recorded, and the reference
// check never runs on it -- so the first row is green off that hole
// and only the second row discriminates: it must go red-to-green when
// the inheritance rule lands and the hole closes.  A body WITH a
// clause is governed by its clause alone (the third and fourth rows,
// green today and required to stay so).  The fifth row is the one
// that tells "governed by its clause alone" from "inherits as well",
// which the third and fourth cannot because their enclosing program
// lacks the name too; the sixth records that inheritance carries only
// what the embed unit itself contains.
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
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-embed-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, src + '\n');
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 120000 });
    const produced = fs.existsSync(wasm);
    fs.rmSync(dir, { recursive: true, force: true });
    return produced ? null : ((c.stdout || '') + (c.stderr || '')).trim().split('\n').filter(l => !l.startsWith('at ')).pop();
}

const PRE = '(import (rnrs) (web html))\n';
const rows = [
    ['a clause-less body may use what the program imports',       PRE + '(define s (conjure js (display 1)))\n(display 1)',                       null],
    ['a clause-less body may not use what the program does not',   PRE + '(define s (conjure js (display (js-eval "1"))))\n(display 1)',        /unbound variable: js-eval/],
    ['a body with its own clause is governed by it: excluded',     PRE + '(define s (conjure js (import (rnrs)) (display (js-eval "1"))))\n(display 1)', /unbound variable: js-eval/],
    ['a body with its own clause is governed by it: included',     PRE + '(define s (conjure js (import (rnrs) (web js)) (display (js-eval "1"))))\n(display 1)', null],
    // the row that separates "governed by its clause alone" from
    // "inherits as well": the clause EXCLUDES a name the enclosing
    // program imports, and the body must not get it back by inheritance
    ['a body clause that excludes a name the program imports wins', '(import (rnrs))\n(define s (conjure js (import (except (rnrs) display)) (display 1)))\n(display 1)', /unbound variable: display/],
    // inheritance carries only what the embed unit contains: the
    // enclosing program's (web js) is spliced into the host, not into
    // the body, so a clause-less body that needs js-eval must say so
    ['a clause-less body does not inherit a host-only library',    '(import (rnrs) (web js))\n(define s (conjure js (display (js-eval "1"))))\n(display 1)', /unbound variable: js-eval/],
];

for (const [title, src, want] of rows) {
    test(title, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
        const err = compileError(src);
        if (want === null) assert.equal(err, null, `refused: ${err}`);
        else { assert.ok(err !== null, 'the program compiled; the body used a name its map does not bring in'); assert.match(err, want); }
    });
}
