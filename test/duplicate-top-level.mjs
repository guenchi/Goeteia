// A top-level name defined twice is a compile-time error by name, on
// both targets.  The flat top level used to let the last definition
// win silently, and dead-code elimination then pruned what only the
// earlier definition called -- the failure surfaced as `cannot call:`
// on an unrelated name (test/probes/dce-shadowed-name.ss).  Each case
// below names the two origins the message must mention.  Compile-time
// failures cannot be expressed by a `;; expect:` line, hence .mjs.
// Introduced (macro-emitted) top-level definitions are distinct per
// expansion and are not duplicates; the last case pins that.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-dup-toplevel-'));

async function refused(name, source, ...mustMention) {
    const f = path.join(dir, `${name}.ss`);
    fs.writeFileSync(f, source, 'utf8');
    for (const target of ['wasm', 'js']) {
        const opts = { script: true, ...(target === 'js' ? { target: 'js' } : {}) };
        await assert.rejects(compileToBytes(f, opts), (e) => {
            // the self-hosted compiler prints its message and traps; rt/compile.mjs
            // keeps what it printed in e.output and the trap in e.message
            const text = [e && e.message, e && e.output].filter(Boolean).join('\n') || String(e);
            // A name the program defines that a library it imports exports
            // is refused by the import rule first -- "NAME is imported by
            // (lib); write (import (except ...)) to define it" -- which names
            // something the author wrote; the duplicate check still catches
            // a genuine double definition.  Either message is a refusal by
            // name, which is what this file asserts.
            assert.match(text, /defined twice|is imported by/, `${name} (${target}): not refused by name: ${text}`);
            for (const m of mustMention) {
                assert.ok(text.includes(m), `${name} (${target}): message does not mention ${m}: ${text}`);
            }
            return true;
        }, `${name} (${target}) compiled`);
    }
}

async function accepted(name, source) {
    const f = path.join(dir, `${name}.ss`);
    fs.writeFileSync(f, source, 'utf8');
    await compileToBytes(f, { script: true });
    await compileToBytes(f, { script: true, target: 'js' });
}

try {
    // one file, one name, two definitions
    await refused('same-file',
        '(import (rnrs))\n(define (use) 1)\n(define use 2)\n(display use)\n',
        'use');
    // the same program with the second definition renamed is fine
    await accepted('same-file-renamed',
        '(import (rnrs))\n(define (use) 1)\n(define used 2)\n(display (+ (use) used))\n');
    // a program redefining a library export: the message names the library
    await refused('program-vs-library',
        '(import (rnrs) (web reactive))\n(define root 3)\n(display root)\n',
        'root', 'web reactive');
    // a program redefining a prelude name
    await refused('program-vs-prelude',
        '(import (rnrs))\n(define (list-tail l n) l)\n(display (list-tail (list 1 2) 1))\n',
        'list-tail');
    // a macro used twice that emits a top-level helper each time is TWO
    // introduced bindings, not one name defined twice (hygiene holds at
    // the top level; test/macro-toplevel-helper.ss pins what it prints)
    await accepted('macro-twice',
        '(import (rnrs))\n(define-syntax with-helper\n  (syntax-rules () ((_ v) (begin (define (helper) v) (display (helper))))))\n' +
        '(with-helper 1)\n(with-helper 2)\n');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
