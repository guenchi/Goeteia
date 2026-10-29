// An inline library that exports a name another imported library also
// exports.  A prefix or except keeps the two bindings distinct, and the
// program compiles and runs; a plain import of both is a genuine
// collision and is refused by name.
//
// The shape is a bridge: a program imports a library, and defines a
// local forwarding function with the same name as the function it
// forwards to.  Reported by a consumer against 1.7.0, who worked around
// it by naming every extension game-*.
//
// The cause: when two scopes define one name, the definitions are keyed
// by their library, and that key was spelt two ways -- joined with "/"
// where the definition was keyed, with " " where a reference resolved
// it.  A library with a one-part name spells both the same, so only a
// library whose name has two or more parts ended up calling a key
// nothing defines.  The self-hosted compiler reported that as
// "unreachable"; the Chez-hosted one as "cannot call".
//
// This cell used to read only the compiler's last line.  The
// self-hosted compiler ends every refusal, however well named, with
// "compile failed: unreachable" after the message, so refusals are now
// judged on the whole text.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import url from 'node:url';

const root = path.join(path.dirname(url.fileURLToPath(import.meta.url)), '..');

// Both compilers: the Chez-hosted one and the self-hosted goeteia.wasm.
const WAYS = [
    ['chez', (ss, out) => spawnSync(path.join(root, 'bin/goeteiac'), [ss, out],
                                    { cwd: root, encoding: 'utf8', timeout: 120000 })],
    ['self', (ss, out) => spawnSync('node', [path.join(root, 'rt/compile.mjs'),
                                             path.join(root, 'goeteia.wasm'), ss, out],
                                    { cwd: root, encoding: 'utf8', timeout: 120000 })],
];

// For each compiler: ['ran', <last line the program printed>] when it
// compiled, otherwise ['refused', <everything the compiler said>].  The
// self-hosted compiler ends every refusal with "compile failed:
// unreachable" after the message itself, so a refusal is judged on the
// whole text, never on its last line.
function outcomes(src) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-reexport-'));
    try {
        const ss = path.join(dir, 'p.ss');
        fs.writeFileSync(ss, src + '\n');
        return WAYS.map(([way, compile], i) => {
            const out = path.join(dir, `p${i}.wasm`);
            const c = compile(ss, out);
            if (!fs.existsSync(out))
                return [way, 'refused', ((c.stdout || '') + (c.stderr || '')).trim()];
            const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), out],
                                { cwd: root, encoding: 'utf8', timeout: 120000 });
            return [way, 'ran', ((r.stdout || '') + (r.stderr || '')).trim().split('\n').pop()];
        });
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

function runs(src, want) {
    assert.deepEqual(outcomes(src), WAYS.map(([w]) => [w, 'ran', want]));
}

function refused(src, message) {
    for (const [way, how, said] of outcomes(src)) {
        assert.equal(how, 'refused', `${way}: compiled, and should not have`);
        assert.ok(said.includes(message), `${way}: refused, but not with "${message}": ${said}`);
    }
}

test('a prefix keeps an inline library export distinct', () => {
    runs("(import (rnrs) (prefix (gam inventory) g:))\n(library (probe bridge)\n  (export make-inventory)\n  (import (rnrs))\n  (define (make-inventory) 42))\n(import (probe bridge))\n(display (make-inventory))", '42');
});

test('except keeps an inline library export distinct', () => {
    runs("(import (rnrs) (except (gam inventory) make-inventory))\n(library (probe bridge)\n  (export make-inventory)\n  (import (rnrs))\n  (define (make-inventory) 42))\n(import (probe bridge))\n(display (make-inventory))", '42');
});

test('a genuine collision is refused by name', () => {
    refused("(import (rnrs) (gam inventory))\n(library (probe bridge)\n  (export make-inventory)\n  (import (rnrs))\n  (define (make-inventory) 42))\n(import (probe bridge))\n(display (make-inventory))",
            'two different bindings imported under one name: make-inventory');
});

test('two two-part libraries defining one name, one of them prefixed', () => {
    runs("(import (rnrs))\n(library (a one) (export f) (import (rnrs)) (define (f) 1))\n(library (b two) (export f) (import (rnrs)) (define (f) 2))\n(import (prefix (a one) a:) (b two))\n(display (list (a:f) (f)))", '(1 2)');
});

test('two two-part libraries defining one name, referenced inside its own library', () => {
    runs("(import (rnrs))\n(library (a one) (export f k) (import (rnrs)) (define (f) 1) (define (k) (f)))\n(library (b two) (export f) (import (rnrs)) (define (f) 2))\n(import (only (a one) k) (b two))\n(display (list (k) (f)))", '(1 2)');
});

// CONTROLS.  They say the inline library mechanism is not the thing at
// fault, so a repair that disabled inline libraries, or keyed names
// differently only where they collide across scopes, would fail here.
test('CONTROL an inline library exporting an unrelated name compiles', () => {
    runs("(import (rnrs) (prefix (gam inventory) g:))\n(library (probe bridge)\n  (export zzz-unrelated-name)\n  (import (rnrs))\n  (define (zzz-unrelated-name) 42))\n(import (probe bridge))\n(display (zzz-unrelated-name))", '42');
});

test('CONTROL the same export compiles when nothing else imports it', () => {
    runs("(import (rnrs) )\n(library (probe bridge)\n  (export make-inventory)\n  (import (rnrs))\n  (define (make-inventory) 42))\n(import (probe bridge))\n(display (make-inventory))", '42');
});

test('CONTROL a two-part collision referenced only inside its own library', () => {
    runs("(import (rnrs))\n(library (a one) (export f k) (import (rnrs)) (define (f) 1) (define (k) (f)))\n(library (b two) (export f) (import (rnrs)) (define (f) 2))\n(import (only (a one) k) (only (b two)))\n(display (k))", '1');
});
