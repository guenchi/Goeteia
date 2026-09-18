// HISTORY, NOT STATUS.  This cell was written red against src/prelude.ss
// at a8add24 and it passes now; it stays as the guard for the rule
// rather than as a report on today's colour.
//
// What was wrong: (exact +nan.0) did not answer and did not abort -- it
// SPUN.  (exact +inf.0) stopped, but by ending the process rather than
// by raising anything a caller could guard.
//
// THE TWO WERE NOT A DESIGN, they were two accidents in one loop, and
// that is why the repair covers both.  Both kinds enter the doubling
// loop; flfloor of an infinity is that infinity, so (fl=? inf inf) is
// true on the first pass and the loop exits at once into
// $fl->exact-integer, where %fl->fx traps.  NaN is never equal to
// itself, so it never takes that exit at all.  One line of the same
// loop decided which failure you got.
//
// MEASURED.  A probe left running by accident held one core at 100.8%
// for forty-seven minutes with no output and no exit status.  Under a
// bound it is rc=124 every time.  Infinities on the same call abort
// immediately instead, which is why this was filed as "no coverage for
// non-finite exact" and not as a hang until something actually ran it.
//
// THE TRACE ENDS IN THE SECOND COND CLAUSE of inexact->exact:
//
//     (let loop ((m mag) (k 1))
//       (if (fl=? m (flfloor m))
//           (let ((v ($make-rat ($fl->exact-integer m) k))) ...)
//           (loop (fl* m (fixnum->flonum 2)) (* k 2))))
//
// (fl=? NaN (flfloor NaN)) is false, as it is for every comparison
// involving NaN, so the loop never takes its exit -- m stays NaN under
// doubling forever.  It is not only non-terminating: k doubles each
// time round, so the loop allocates an unbounded bignum as it goes.
//
// WHY THIS CELL IS .mjs AND NOT .ss.  A Scheme cell would hang the
// round until run-tests.sh's 180s cap, and the runner reports that as
// TIMEOUT -- which reads as flakiness, the one verdict that gets a
// re-run rather than a bug report.  Here each row is a separate process
// under its own bound, so a spin is a MEASUREMENT with a name.
//
// A hang is the failure a suite reports worst, so the rows below are
// written to say which of three things happened, never just "not ok":
// answered (with what), aborted (with what message), or spun.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Ten seconds is four orders of magnitude more than this call needs;
// an ordinary exact conversion is a handful of instructions.  The bound
// is here to name a spin, not to race a slow machine.
const BOUND_MS = 10000;

function evaluate(expr) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-exact-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, '(import (rnrs))\n(display ' + expr + ')\n');
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm],
                        { encoding: 'utf8', timeout: 120000 });
    if (!fs.existsSync(wasm)) {
        fs.rmSync(dir, { recursive: true, force: true });
        return { kind: 'compile-error', detail: ((c.stdout || '') + (c.stderr || '')).trim() };
    }
    const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), wasm],
                        { encoding: 'utf8', timeout: BOUND_MS });
    fs.rmSync(dir, { recursive: true, force: true });
    // A timeout comes back as a killing signal, or as an ETIMEDOUT
    // error, depending on the platform; both mean the same thing here
    // and neither is a status this program could have exited with.
    if (r.error?.code === 'ETIMEDOUT' || r.signal) return { kind: 'spun' };
    const text = ((r.stdout || '') + (r.stderr || '')).trim();
    const first = text.split('\n')[0];
    // FOUR OUTCOMES, NOT THREE.  The first version of this had one
    // bucket for "exited non-zero" and called it aborted, and that is
    // wrong in the direction that matters: a RAISED condition nobody
    // guarded also exits non-zero.  The cell then said both "a caller
    // can guard +inf.0" (pass) and "+inf.0 raises rather than aborts"
    // (fail) in the same run -- two rows that cannot both be right,
    // which is how the missing bucket was found.
    //
    // The runtime distinguishes them in the text and nowhere else: a
    // condition that reaches the top prints "unhandled exception: "
    // first, and a wasm trap prints the trap's own words with no such
    // prefix ("float unrepresentable in integer range", "array element
    // access out of bounds").  Exit status is 1 for both.
    if (r.status !== 0) {
        return first.startsWith('unhandled exception:')
            ? { kind: 'raised', detail: first }
            : { kind: 'trapped', detail: first };
    }
    return { kind: 'answered', detail: text };
}

// The three rows that are red.  They are three rather than one because
// a repair can be put in the wrong place and still turn one of them
// green: guarding `exact` alone leaves inexact->exact spinning, and
// special-casing the literal leaves the computed NaN spinning.
const red = [
    ['(exact +nan.0)', '(exact +nan.0)'],
    ['(inexact->exact +nan.0) -- exact is a one-line alias for it, so a guard put in exact only would leave this one spinning',
     '(inexact->exact +nan.0)'],
    ['(exact (/ 0.0 0.0)) -- a NaN the reader never saw, so this is not an artifact of reading the literal',
     '(exact (/ 0.0 0.0))'],
];

for (const [name, expr] of red) {
    test('it returns: ' + name, () => {
        const r = evaluate(expr);
        assert.notEqual(r.kind, 'spun',
            expr + ' did not return within ' + BOUND_MS + 'ms');
    });
}

// CONTROLS, and they are the reason this cell cannot be satisfied by
// making inexact->exact refuse everything.  The loop that spins on NaN
// is the SAME loop that does the real work for a fractional double, so
// a repair has to leave it reachable.
const green = [
    ['a fraction still converts', '(exact 0.5)', '1/2'],
    ['a fraction that needs several doublings', '(exact 0.125)', '1/8'],
    ['an integral double still converts', '(exact 3.0)', '3'],
    ['a negative fraction keeps its sign', '(exact -0.5)', '-1/2'],
    // Past the fixnum range the first clause does not apply, so this
    // goes through $fl->exact-integer -- the other half of the code the
    // repair must not disturb.
    ['a double past the fixnum range still converts', '(exact 1073741824.0)', '1073741824'],
    ['an exact argument is returned unchanged', '(exact 7)', '7'],
];

for (const [name, expr, want] of green) {
    test('CONTROL ' + name, () => {
        const r = evaluate(expr);
        assert.deepEqual([r.kind, r.detail], ['answered', want]);
    });
}

// THE INFINITIES ARE IN SCOPE, and how they got here is worth the four
// lines.  They were left out of the rows above on the reading that they
// "already stop", and the difference looked like design: NaN hangs,
// infinities abort.  Reading the branch settles that it is not design.
// Both kinds enter the SAME loop; flfloor of an infinity is that
// infinity, so (fl=? inf inf) is true on the first pass and the loop
// exits at once into $fl->exact-integer, where %fl->fx traps on
// something it cannot represent.  Nothing chose the abort.  It is what
// one primitive does when handed a value nobody checked, and it leaves
// one procedure answering "there is no exact equivalent" two different
// ways depending on which line of one loop the argument happens to
// reach.
//
// So the question is not "be consistent with the infinities" -- it is
// which of the two accidents to keep, and the answer is neither.  A
// spin reads as still running.  An abort is loud but ends the process.
// A condition is loud AND recoverable, which beats both on both axes,
// and R6RS names it: an inexact with no reasonably close exact
// equivalent may raise &implementation-restriction.  A trap is not a
// condition, so what the tree does today is not one of the standard's
// options.
// The irritant text is MEASURED, not guessed.  It used to read
// <big-flonum>, because this runtime rendered an infinity as a
// placeholder rather than as +inf.0 -- so the condition named the SIGN
// and not the value, and this cell pinned that spelling with a note
// saying it recorded what the message said rather than what it should.
//
// The writer was repaired in the same batch as this line moved, so the
// irritant now names the value.  Keeping the note would have been worse
// than deleting it: a comment that says "this is wrong but pinned
// anyway" goes stale the moment it is right, and then it argues against
// a repair that has already happened.
for (const [expr, irritant] of [
    ['(exact +inf.0)', '+inf.0'],
    ['(exact -inf.0)', '-inf.0'],
    ['(inexact->exact +inf.0)', '+inf.0'],
]) {
    test('it raises rather than traps: ' + expr, () => {
        const r = evaluate(expr);
        assert.deepEqual([r.kind, r.detail],
            ['raised', 'unhandled exception: inexact->exact: no exact equivalent ' + irritant]);
    });
}

// CONTROL FOR THE CLASSIFIER ITSELF.  Every row above asks it to answer
// 'raised'; nothing above would notice if it had started answering
// 'raised' for everything.  A wasm trap is the other side, and this is
// one: an out-of-range vector index is a trap in this runtime, with the
// trap's own words and no "unhandled exception:" in front of them.
test('CONTROL a real trap still reads as trapped, so the classifier discriminates', () => {
    const r = evaluate('(vector-ref (vector 1) 9)');
    assert.equal(r.kind, 'trapped');
    assert.match(r.detail, /out of bounds/);
});

// RECOVERABLE IS THE WHOLE CLAIM, so it gets rows of its own rather
// than being inferred from "did not abort".  A repair that answered
// some sentinel value would satisfy every row above and quietly put a
// wrong number into the caller's arithmetic; these rows fail it,
// because the guard only runs if something was raised.
//
// exact is reached from data, not only from a literal: a parsed float,
// a division that went 0/0, a reading off a device.  A caller walking a
// million rows has to be able to skip the bad row and say which one.
// That is a thing only a condition permits, which is why it is checked
// here and not left as a remark.
for (const [name, expr] of [
    ['NaN', '+nan.0'],
    ['positive infinity', '+inf.0'],
    ['negative infinity', '-inf.0'],
]) {
    test('a caller can guard it: ' + name, () => {
        const r = evaluate("(guard (e (#t (list 'CAUGHT (condition-who e)))) (exact " + expr + "))");
        assert.deepEqual([r.kind, r.detail], ['answered', '(CAUGHT inexact->exact)']);
    });
}

// CONTROL for the three rows above: guard is not swallowing an ordinary
// answer.  Without this, a repair that raised on EVERY argument would
// read as success there -- and the controls further up only cover the
// unguarded calls.
test('CONTROL guard does not fire on an ordinary argument', () => {
    const r = evaluate("(guard (e (#t 'CAUGHT)) (exact 0.5))");
    assert.deepEqual([r.kind, r.detail], ['answered', '1/2']);
});
