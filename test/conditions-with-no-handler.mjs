// What a program prints, and whether it goes on, when a condition meets no
// handler (ledger R20f).
//
// R6RS 7.1: with no handler installed, a &serious condition interrupts the
// program, and the handler "is expected to return when passed any other
// non-&serious condition".  So:
//   - a &serious condition, or an object that is not a condition, prints
//     `unhandled exception: ` and its report and stops the program -- at
//     once, without running the after thunks of the dynamic-winds it is in;
//   - a condition that is not &serious prints `warning: ` and its report
//     and the raise-continuable RETURNS; a `raise` of it then raises
//     &non-continuable, which is serious;
//   - the report is `who: message irritant ...` for a condition with a
//     message (the who printed as #f when there is none), else the object
//     written: a record as #<NAME> with its type's name, as every
//     record is written, and a compound condition as #<condition ...>
//     with its components' type names.
// A program that never installs a handler does not carry the handler loop
// or the condition types error would use: error and the prelude's own
// reports print their line directly.  The `stops` rows are therefore run
// twice, in a program that installs no handler and in one that installed
// and left one, and must print the same.
// Rows marked OWN are goeteia's reading where Chez differs: Chez returns
// only for a &warning (a bare &message stops there), and Chez runs pending
// after thunks when it stops.
//
// BEFORE THE CHANGE with-exception-handler and the condition types are
// unbound, raise-continuable never returns, and a failed assert is an &error.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileSource } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const P = '(import (rnrs))\n';
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'no-handler-'));
let serial = 0;
// -> { stopped, text }: everything the program wrote, and whether it stopped
async function run(body, target) {
    const made = await compileSource(P + body, { name: 'conditions-with-no-handler', ...(target === 'js' ? { target: 'js' } : {}) });
    try {
        if (target === 'js') {
            const file = path.join(dir, `p${serial++}.mjs`);
            fs.writeFileSync(file, made);
            return { stopped: false, text: (await runJsModule(file)).text };
        }
        return { stopped: false, text: (await runModule(made)).text };
    } catch (e) {
        return { stopped: true, text: e.output ?? '', message: e.message };
    }
}
const lines = t => t.split('\n').map(l => l.trim()).filter(Boolean);

const stops = [
    ['raise of a symbol', `(display "before")(newline)(raise 'boom)(display "after")`,
     /^unhandled exception: boom$/],
    ['error', `(display "before")(newline)(error 'who "went wrong" 1 "two")(display "after")`,
     /^unhandled exception: who: went wrong 1 "two"$/],
    ['error with no who', `(display "before")(newline)(error #f "went wrong")(display "after")`,
     /^unhandled exception: #f: went wrong$/],
    ['assertion-violation', `(display "before")(newline)(assertion-violation 'f "bad" 'x)(display "after")`,
     /^unhandled exception: f: bad x$/],
    ['a failed assert', `(display "before")(newline)(assert (= 1 2))(display "after")`,
     /^unhandled exception: assert: /],
    ['raise-continuable of a number', `(display "before")(newline)(raise-continuable 42)(display "after")`,
     /^unhandled exception: 42$/],
    ['a serious condition without a message', `(display "before")(newline)(raise (make-violation))(display "after")`,
     /^unhandled exception: #<&violation>$/],
    ['a compound with a serious component, raised continuably',
     `(display "before")(newline)(raise-continuable (condition (make-warning) (make-error)))(display "after")`,
     /^unhandled exception: #<condition &warning &error>$/],
];
for (const target of ['wasm', 'js']) {
    for (const [name, body, last] of stops) {
        test(`stops (${target}): ${name}`, async () => {
            const r = await run(body, target);
            assert.ok(r.stopped, `the program went on:\n${r.text}`);
            const ls = lines(r.text);
            assert.equal(ls[0], 'before');
            assert.match(ls[ls.length - 1], last);
            assert.ok(!ls.includes('after'));
        });
    }

    // The same lines when a handler has been installed and left earlier in
    // the program: a program that never installs one does not carry the
    // handler machinery, and the two ways to the report must print alike.
    for (const [name, body, last] of stops) {
        test(`stops after a handler was installed and left (${target}): ${name}`, async () => {
            const r = await run(`(guard (e (#t #f)) (raise 'earlier))\n(with-exception-handler (lambda (c) 0) (lambda () (raise-continuable 'earlier)))\n${body}`, target);
            assert.ok(r.stopped, `the program went on:\n${r.text}`);
            const ls = lines(r.text);
            assert.equal(ls[0], 'before');
            assert.match(ls[ls.length - 1], last);
            assert.ok(!ls.includes('after'));
        });
    }

    test(`a warning with no handler is reported and the call returns (${target})`, async () => {
        const r = await run(`(display "before")(newline)(raise-continuable (make-warning))(newline)(display "after")`, target);
        assert.ok(!r.stopped, `the program stopped:\n${r.text}\n${r.message}`);
        assert.deepEqual(lines(r.text), ['before', 'warning: #<&warning>', 'after']);
    });

    test(`a warning with a message and a who (${target})`, async () => {
        const r = await run(
            `(raise-continuable (condition (make-warning) (make-who-condition 'loader) (make-message-condition "slow") (make-irritants-condition '(3))))(newline)(display "after")`, target);
        assert.ok(!r.stopped);
        assert.deepEqual(lines(r.text), ['warning: loader: slow 3', 'after']);
    });

    test(`OWN: a bare &message is not serious, so it returns too (Chez stops) (${target})`, async () => {
        const r = await run(`(raise-continuable (make-message-condition "m"))(newline)(display "after")`, target);
        assert.ok(!r.stopped);
        assert.deepEqual(lines(r.text), ['warning: #f: m', 'after']);
    });

    test(`raise of a warning: the warning line, then &non-continuable stops the program (${target})`, async () => {
        const r = await run(`(display "before")(newline)(raise (make-warning))(display "after")`, target);
        assert.ok(r.stopped, `the program went on:\n${r.text}`);
        const ls = lines(r.text);
        assert.equal(ls[1], 'warning: #<&warning>');
        assert.match(ls[ls.length - 1], /^unhandled exception: .*non-continuable/);
        assert.ok(!ls.includes('after'));
    });

    test(`a handler that returns from raise: &non-continuable with no handler left (${target})`, async () => {
        const r = await run(
            `(with-exception-handler (lambda (c) (display "handled ") (display c) (newline) 0) (lambda () (raise 'boom)))(display "after")`, target);
        assert.ok(r.stopped);
        const ls = lines(r.text);
        assert.equal(ls[0], 'handled boom');
        assert.match(ls[ls.length - 1], /^unhandled exception: .*non-continuable/);
    });

    test(`OWN: an uncaught condition under a guard that does not match: the thunks of the leave and the re-entry run, then it stops at once (${target})`, async () => {
        const r = await run(
            `(guard (e ((string? e) 'no))\n` +
            `  (dynamic-wind (lambda () (display "in") (newline))\n` +
            `                (lambda () (raise 'boom))\n` +
            `                (lambda () (display "out") (newline))))\n(display "after")`, target);
        assert.ok(r.stopped);
        assert.deepEqual(lines(r.text), ['in', 'out', 'in', 'unhandled exception: boom']);
    });

    test(`a warning under a guard that does not match returns into the body (${target})`, async () => {
        const r = await run(
            `(display (guard (e ((string? e) 'no))\n` +
            `  (dynamic-wind (lambda () (display "in") (newline))\n` +
            `                (lambda () (raise-continuable (make-warning)) (newline) 'body-went-on)\n` +
            `                (lambda () (display "out") (newline)))))`, target);
        assert.ok(!r.stopped, `${r.text}\n${r.message}`);
        assert.deepEqual(lines(r.text), ['in', 'out', 'in', 'warning: #<&warning>', 'out', 'body-went-on']);
    });
}
