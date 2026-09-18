// EXPECTED FAIL against src/prelude.ss.  A non-finite number cannot make
// the round trip through text, and it fails at BOTH ends independently.
//
// R6RS 11.7.4.4 requires that number->string produce a string which
// string->number reads back as an equivalent number, and names +inf.0,
// -inf.0, +nan.0 and -nan.0 as the external representations.  This
// runtime writes something else and reads neither.
//
// MEASURED, and the two halves are separate defects that happen to
// cancel each other in casual use, which is why neither has been
// noticed: nobody writes an infinity and reads it back in one step.
//
//   (number->string +inf.0)   -> "<big-flonum>"    not readable, not R6RS
//   (number->string -inf.0)   -> "-<big-flonum>"   sign survives, value does not
//   (number->string +nan.0)   -> "+nan.0"          CORRECT text
//   (string->number "+inf.0") -> #f                the reader refuses it
//   (string->number "-inf.0") -> #f
//   (string->number "+nan.0") -> #f                refuses its OWN output
//
// THE NaN ROW IS THE ONE THAT SETTLES IT.  If only the writer were
// broken, a correct writer would fix the round trip; if only the reader
// were, the same.  NaN shows both are broken at once: the writer already
// emits exactly the text the standard asks for, and the reader still
// answers #f.  So this is two repairs, not one, and a cell that only
// checked the round trip could be satisfied by repairing neither end
// properly -- by making the writer emit whatever this reader happens to
// accept.
//
// WHERE IT BITES.  The compiler's own reader handles +inf.0 in source:
// this file's fixtures are written with those literals and they compile.
// It is string->number, the procedure a PROGRAM calls, that refuses
// them -- so a parser reading a data file, a JSON-ish decoder, or any
// caller taking numbers from text silently gets #f where the text said
// infinity.  #f is not a number, so the failure surfaces somewhere else
// entirely, as a type error in whatever consumed the parse.
//
// IT IS ALSO WHY AN ERROR MESSAGE CANNOT NAME THE VALUE.  With the
// non-finite guard in inexact->exact, the irritant for an infinity
// prints as <big-flonum>: the condition says which sign it was handed
// and not which value.  test/defect-exact-of-nan-never-returns.mjs pins
// that text as it is today and points here for the reason.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function evaluate(expr) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-nonfinite-'));
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
                        { encoding: 'utf8', timeout: 20000 });
    fs.rmSync(dir, { recursive: true, force: true });
    const text = ((r.stdout || '') + (r.stderr || '')).trim();
    if (r.status !== 0) return { kind: 'failed', detail: text.split('\n')[0] };
    return { kind: 'answered', detail: text };
}

// ---- the writer

for (const [name, expr, want] of [
    ['+inf.0 writes as itself', '(number->string +inf.0)', '+inf.0'],
    ['-inf.0 writes as itself', '(number->string -inf.0)', '-inf.0'],
    // Already correct.  It is here as the row that proves the writer is
    // capable of the right answer, so "the writer cannot do this" is not
    // an available explanation for the two above.
    ['+nan.0 writes as itself', '(number->string +nan.0)', '+nan.0'],
]) {
    test('writer: ' + name, () => {
        assert.deepEqual(evaluate(expr), { kind: 'answered', detail: want });
    });
}

// ---- the reader, which is a separate defect and is checked separately
// rather than through the round trip, so that repairing one end cannot
// make the other look repaired.

for (const [name, text] of [
    ['+inf.0', '+inf.0'],
    ['-inf.0', '-inf.0'],
    ['+nan.0', '+nan.0'],
    ['-nan.0', '-nan.0'],
]) {
    test('reader: string->number accepts ' + name, () => {
        const r = evaluate('(let ((v (string->number "' + text + '"))) '
                           + '(if v (list (quote read) (if (= v v) (quote finite-or-inf) (quote nan))) (quote REFUSED)))');
        assert.equal(r.kind, 'answered');
        assert.notEqual(r.detail, 'REFUSED', 'string->number refused "' + text + '"');
    });
}

// ---- and only then the round trip, which is what R6RS actually asks
// for.  It is last because it is the weakest of the three: it can be
// satisfied by a writer that emits whatever this reader happens to take,
// which would be conformant with nothing.

for (const expr of ['+inf.0', '-inf.0', '+nan.0']) {
    test('round trip: ' + expr + ' survives number->string and back', () => {
        const r = evaluate('(let* ((x ' + expr + ') (s (number->string x)) (y (string->number s))) '
                           + '(if (not y) (quote REFUSED) (if (= x x) (if (= x y) (quote same) (quote different)) '
                           + '(if (= y y) (quote different) (quote same)))))');
        assert.deepEqual([r.kind, r.detail], ['answered', 'same']);
    });
}

// CONTROLS.  Ordinary numbers make the trip, so a repair cannot be
// "make string->number answer something for every string" and cannot
// break the writer's existing behaviour.  The large and small magnitudes
// are here because they are the finite values nearest the boundary this
// is about.
for (const [expr, want] of [
    ['(number->string 1.5)', '1.5'],
    ['(number->string 1e300)', '1e300'],
    ['(number->string 0.0)', '0.0'],
    ['(number->string 7)', '7'],
    ['(string->number "1.5")', '1.5'],
    ['(string->number "1e300")', '1e300'],
    // A string that is not a number at all must still answer #f: the
    // reader's refusal is correct behaviour here and must survive a
    // repair aimed at the four literals above.
    ['(string->number "banana")', '#f'],
    ['(string->number "+inf")', '#f'],
    ['(string->number "inf.0")', '#f'],
]) {
    test('CONTROL ' + expr, () => {
        assert.deepEqual(evaluate(expr), { kind: 'answered', detail: want });
    });
}
