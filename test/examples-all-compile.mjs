// Nothing in this tree compiled examples/ until this cell existed, and
// three of the forty-six had not compiled since 2026-09-11.
//
// WHAT HAPPENED.  0647569 narrowed the prelude exemption in
// bound-in-scope?, adding (not (memq n $rnrs-exports)) so that an (rnrs)
// export must come from the form's own import clause rather than from
// the prelude's scope.  That was deliberate and it is right -- its own
// message says "excluding map and calling it is unbound now" -- and the
// convention it enforces was already near-universal here: 43 of the 46
// examples wrote (import (rnrs) ...).  The three that did not are
// exactly the three that stopped compiling.  The two sets are identical,
// which says more than a compile census does: not "three broke", but
// "three were outside a convention that nothing checked".
//
// They stayed broken across 1.7.1 and 1.7.2.  Two releases shipped with
// three uncompilable examples and a generator script that could not run,
// because run-tests.sh mentions examples/ nowhere and no cell read one.
//
// WHAT THIS CELL IS AND IS NOT.  It compiles every examples/*.ss and
// requires each to succeed.  It does NOT run them, does not look at what
// they draw, and does not check that any committed artifact beside them
// -- 39 .wasm and 47 .html files are tracked under examples/, and only
// one of them has a committed generator -- is current.  The freshness of
// those artifacts is a separate question with its own entry on the
// ledger; this cell would stay green with every one of them stale.
//
// Cost measured before it was written: 46 compilations in 35 seconds,
// against run-tests.sh's 180-second cap.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const examples = fs.readdirSync(path.join(root, 'examples'))
    .filter(n => n.endsWith('.ss')).sort();

const out = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-examples-'));

function compile(name) {
    const r = spawnSync(path.join(root, 'bin/goeteiac'),
                        [path.join('examples', name), path.join(out, 'a.wasm')],
                        { cwd: root, encoding: 'utf8', timeout: 120000 });
    const text = ((r.stdout || '') + (r.stderr || '')).trim();
    return { ok: r.status === 0, last: text.split('\n').filter(Boolean).pop() || '' };
}

// THE COUNT IS A ROW.  An empty list satisfies "every example compiles",
// so a readdir that found nothing -- a renamed directory, a filter that
// stopped matching -- would read as success.  The number is asserted
// against the low end rather than pinned exactly, because adding an
// example must not turn this red.
test('there are examples to compile', () => {
    assert.ok(examples.length >= 40,
        `found ${examples.length} examples/*.ss, expected at least 40`);
});

for (const name of examples) {
    test('examples/' + name + ' compiles', () => {
        const r = compile(name);
        assert.ok(r.ok, 'examples/' + name + ' did not compile: ' + r.last);
    });
}

// CONTROL.  Every row above asks the compiler to succeed, and nothing
// there would notice if bin/goeteiac had started exiting 0 on anything
// handed to it -- the stub-that-answers-yes shape, applied to a
// compiler.  This program is the defect the batch was about, in its
// smallest form: an (rnrs) export used without an import clause naming
// it.  It must still be refused, and refused for that reason.
test('CONTROL the compiler still refuses an unbound rnrs name', () => {
    const p = path.join(out, 'unbound.ss');
    fs.writeFileSync(p, '(import (web html))\n(display (+ 1 2))\n');
    const r = spawnSync(path.join(root, 'bin/goeteiac'), [p, path.join(out, 'b.wasm')],
                        { cwd: root, encoding: 'utf8', timeout: 120000 });
    assert.notEqual(r.status, 0, 'a program using + without importing (rnrs) compiled');
    assert.match(((r.stdout || '') + (r.stderr || '')), /unbound variable/);
});

// CONTROL for the control: the same program WITH the import compiles, so
// the row above is about the missing clause and not about anything else
// in that two-line file.
test('CONTROL the same program with (rnrs) compiles', () => {
    const p = path.join(out, 'bound.ss');
    fs.writeFileSync(p, '(import (rnrs) (web html))\n(display (+ 1 2))\n');
    const r = spawnSync(path.join(root, 'bin/goeteiac'), [p, path.join(out, 'c.wasm')],
                        { cwd: root, encoding: 'utf8', timeout: 120000 });
    assert.equal(r.status, 0,
        'the control program did not compile: ' + ((r.stdout || '') + (r.stderr || '')).trim());
});

test('cleanup', () => {
    fs.rmSync(out, { recursive: true, force: true });
});
