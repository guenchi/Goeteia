// EXPECTED FAIL against src/compiler.ss at 346ede4.  An inline library
// that EXPORTS a name another imported library also exports makes the
// compiler die with "unreachable" instead of either compiling or
// refusing by name.
//
// The shape is a bridge: a program imports a library, and defines a
// local forwarding function with the same name as the function it
// forwards to.  That is an ordinary thing to write, and the whole point
// of a prefix is that it makes the two bindings distinct.
//
// WHAT IS NOT THE TRIGGER, measured by bisecting rather than guessed:
// the inline library itself is fine -- exporting a fresh name compiles,
// and exporting `make-inventory` compiles too as long as the enclosing
// program does not import the library that also exports it.  The
// trigger is the pair.
//
// THREE THINGS FAIL AT ONCE AND THE THIRD IS THE WORST.
//
// A prefix does not help, and preventing exactly this collision is what
// a prefix is for.
//
// `except` does not help either, and that is the remedy this tree's own
// import rule NAMES: its refusal message reads "imported name may not
// be defined; exclude it with except: <name>".  So the documented way
// out of the collision walks into the same crash.
//
// And the failure is a CRASH, not a diagnostic.  Even the row that is a
// genuine collision -- plain import, same name -- should reach the
// named refusal this tree already has machinery for, asserted in
// test/import-refusals.mjs.  This path bypasses it, so a program that
// should be told what it did wrong is told "unreachable" instead.
//
// Reported by a consumer against 1.7.0, who worked around it by naming
// every extension `game-*`; reproduced here on 1.7.2 unchanged.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';

const here = path.dirname(url.fileURLToPath(import.meta.url));
const root = path.join(here, '..');

// Returns null when the program compiled, otherwise the last line the
// compiler said.  The distinction the rows below care about is not
// "did it fail" but "did it say something a reader can act on".
function compileOutcome(src) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-inline-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, src + '\n');
    const c = spawnSync('node', [path.join(root, 'rt/compile.mjs'),
                                 path.join(root, 'goeteia.wasm'), ss, wasm],
                        { encoding: 'utf8', timeout: 120000 });
    const produced = fs.existsSync(wasm);
    const said = ((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop();
    fs.rmSync(dir, { recursive: true, force: true });
    return produced ? null : said;
}

const bridge = (outer, name) =>
    `(import (rnrs) ${outer})
(library (probe bridge)
  (export ${name})
  (import (rnrs))
  (define (${name}) 42))
(import (probe bridge))
(display (${name}))`;

test('a prefix keeps an inline library export distinct', () => {
    assert.equal(compileOutcome(bridge('(prefix (gam inventory) g:)',
                                       'make-inventory')),
                 null,
                 'a prefixed import must not collide with an inline export');
});

test('except keeps an inline library export distinct', () => {
    assert.equal(compileOutcome(bridge('(except (gam inventory) make-inventory)',
                                       'make-inventory')),
                 null,
                 'except is the remedy this tree names; it must work here');
});

test('a genuine collision is refused by name, not by crashing', () => {
    const said = compileOutcome(bridge('(gam inventory)', 'make-inventory'));
    assert.ok(said !== null, 'a real collision must not compile');
    assert.doesNotMatch(said, /unreachable/,
        'the compiler crashed where it has a named refusal for this');
    assert.match(said, /imported name|except/,
        `a collision must say what it was and how to resolve it: ${said}`);
});

// CONTROLS.  These pass today and must keep passing: they are what says
// the inline library mechanism is not the thing at fault, so a repair
// that disabled inline libraries would satisfy the rows above and fail
// here.
test('CONTROL an inline library exporting an unrelated name compiles', () => {
    assert.equal(compileOutcome(bridge('(prefix (gam inventory) g:)',
                                       'zzz-unrelated-name')), null);
});

test('CONTROL the same export compiles when nothing else imports it', () => {
    assert.equal(compileOutcome(bridge('', 'make-inventory')), null);
});
