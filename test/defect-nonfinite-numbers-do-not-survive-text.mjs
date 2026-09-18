// HISTORY, NOT STATUS.  This cell was written red against src/prelude.ss
// at 11b31d0 and it passes now; it stays as the guard for the rules
// below rather than as a report on today's colour.
//
// What was wrong: a non-finite number could not make the round trip
// through text, and it failed at BOTH ends independently.
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
// AND THE GAP WAS WIDER THAN NON-FINITE.  string->number was a proper
// SUBSET of the source reader -- ratios and complex numerals answered #f
// too -- and for a zero denominator it did not answer at all: it RAISED,
// with the reader's own message and a position it had no business
// having, "at line 1 column 0", to a caller that never read a line.  The
// mechanism was a predicate that decided by running the parser, so the
// parser's error walked out through a yes-or-no question.
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

// ---- THE SAME TEXT, AGAINST THE HOST READER.
//
// CORRECTED.  These rows were written as "the two readers in this tree
// must agree", and that was wrong about which reader parses the literal.
// bin/goeteiac is a CHEZ-hosted driver -- src/chez-driver.ss reads source
// forms with Chez's own (read port) -- so a literal in the fixture is
// parsed by CHEZ, not by goeteia's %finish-atom.  Measured with a
// discriminator: a source file containing the literal #i1/0 COMPILES
// through bin/goeteiac and prints an infinity, while goeteia's own reader
// raises on that spelling.  The comment asserted a fact about this tree
// that is not true of it.
//
// The rows stay, relabelled, because what they actually compare is
// BETTER than what I claimed: string->number's answer against a
// REFERENCE IMPLEMENTATION's reading of the same characters.  An
// expectation taken from Chez comes from outside this tree; one taken
// from our own reader would let both be wrong together, which is the
// trap the control below was added for and which this framing avoids
// entirely.
//
// The in-tree invariant is real and gets its own group, further down,
// using (with-input-from-string s read) -- read AT RUNTIME is goeteia's
// %finish-atom, so that comparison is the one the repair is about.
for (const [name, text, literal] of [
    ['a ratio', '3/4', '3/4'],
    ['a negative ratio', '-7/2', '-7/2'],
    ['a complex number', '1+2i', '1+2i'],
    ['a pure imaginary', '+2i', '+2i'],
    ['i on its own', '-i', '-i'],
    ['a complex number with a negative part', '2-3i', '2-3i'],
]) {
    test('string->number agrees with the host reader on ' + name + ': ' + text, () => {
        const r = evaluate('(let ((from-text (string->number "' + text + '")) (from-source ' + literal + ')) '
                           + '(if (not from-text) (quote REFUSED) '
                           + '(if (equal? from-text from-source) (quote same) '
                           + '(list (quote different) from-text from-source))))');
        assert.deepEqual([r.kind, r.detail], ['answered', 'same']);
    });
}

// The non-finite spellings get the same invariant, and they need their
// own comparison because equal? is false for NaN against itself -- the
// one value that is not equal to itself is the one this cell opened on.
for (const [name, text, literal] of [
    ['positive infinity', '+inf.0', '+inf.0'],
    ['negative infinity', '-inf.0', '-inf.0'],
]) {
    test('string->number agrees with the host reader on ' + name + ': ' + text, () => {
        const r = evaluate('(let ((a (string->number "' + text + '")) (b ' + literal + ')) '
                           + '(if (not a) (quote REFUSED) (if (= a b) (quote same) (quote different))))');
        assert.deepEqual([r.kind, r.detail], ['answered', 'same']);
    });
}

test('string->number answers a NaN for "+nan.0", checked by property', () => {
    const r = evaluate('(let ((a (string->number "+nan.0"))) '
                       + '(if (not a) (quote REFUSED) '
                       + '(if (and (real? a) (not (= a a))) (quote same) (quote different))))');
    assert.deepEqual([r.kind, r.detail], ['answered', 'same']);
});

// ---- THE TWO READERS IN THIS TREE, which is what the group above was
// mislabelled as.  read AT RUNTIME is goeteia's %finish-atom, reached
// through with-input-from-string, so both sides of this comparison are
// this implementation and the rows say what the repair is for: one text,
// one grammar, two entry points that must not diverge.
//
// A symbol is a legal answer to give text, so a row that only asked "did
// read answer something" would pass when the reader silently stopped
// recognising a numeral.  Each row therefore requires a NUMBER and
// requires the two to be equal.
for (const text of ['3/4', '-7/2', '1+2i', '+2i', '-i', '2-3i', '+inf.0', '-inf.0', '42', '1.5', '1e5']) {
    test('the tree\'s own two readers agree on ' + text, () => {
        const r = evaluate('(let ((a (string->number "' + text + '")) '
                           + '(b (with-input-from-string "' + text + '" read))) '
                           + '(cond ((not a) (quote REFUSED-BY-STRING->NUMBER)) '
                           + '((not (number? b)) (list (quote READ-DID-NOT-ANSWER-A-NUMBER) b)) '
                           + '((= a b) (quote same)) (else (list (quote different) a b))))');
        assert.deepEqual([r.kind, r.detail], ['answered', 'same']);
    });
}

// ---- WHAT THE READER MUST NOT QUIETLY STOP DOING.
//
// These rows exist because of a hazard found by walking the complex path
// during implementation rather than by any test: a zero denominator has
// THREE positions -- the token itself, the real part of a complex
// numeral, and the imaginary part -- and refusing it in only the first
// makes "1/0+2i" match nothing, so %finish-atom falls through to its
// symbol clause and (read "1/0+2i") becomes the SYMBOL 1/0+2i where it
// used to raise.  Chez raises.
//
// Nothing else here would notice.  This cell is about text that should
// be refused, and answering a symbol IS a refusal to read it as a
// number -- the failure is that the refusal moved from an error to a
// datum, which is a change in KIND that a value comparison cannot see.
for (const text of ['1/0', '1/0+2i', '2+1/0i', '+1/0i', '#x1/0', '#e1/0']) {
    test('read still REFUSES ' + text + ' rather than answering a symbol', () => {
        const r = evaluate('(guard (e (#t (quote RAISED))) '
                           + '(let ((v (with-input-from-string "' + text + '" read))) '
                           + '(list (quote ANSWERED) v (if (symbol? v) (quote a-symbol) (quote not-a-symbol)))))');
        assert.deepEqual([r.kind, r.detail], ['answered', 'RAISED']);
    });
}

// CONTROL for the group above: the reader still READS the shapes that
// differ from those by one character, so "make read raise more often"
// is not an available repair.
for (const [text, want] of [['3/4', '3/4'], ['1/2+2i', '1/2+2i'], ['#x1/2', '1/2']]) {
    test('CONTROL read still accepts ' + text, () => {
        const r = evaluate('(with-input-from-string "' + text + '" read)');
        assert.deepEqual([r.kind, r.detail], ['answered', want]);
    });
}

// CONTROL FOR THE INVARIANT ITSELF.  Every row above passes if both
// readers are wrong in the same way, so one row pins a value the source
// reader is known to get right and checks it against arithmetic done
// elsewhere.  Without it, "they agree" would be satisfied by two readers
// agreeing on nonsense.
test('CONTROL the source reader is right about the one the rows compare against', () => {
    const r = evaluate('(list (= 3/4 (/ 3 4)) (= -7/2 (/ -7 2)) '
                       + '(= 1+2i (make-rectangular 1 2)) (= +2i (make-rectangular 0 2)))');
    assert.deepEqual([r.kind, r.detail], ['answered', '(#t #t #t #t)']);
});

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
    // THE BOUNDARIES OF THE FINITE PRINTER, which the infinity clause
    // sits in the same cond as.  Without these a repair could reach past
    // its own clause and nothing here would say so.  Every expectation
    // was measured before being written down, including the two that
    // read oddly: a negative zero keeps its sign, and 2.5e-10 comes out
    // in positional form rather than with an exponent.
    ['(number->string -1.5)', '-1.5'],
    ['(number->string -0.0)', '-0.0'],
    ['(number->string 5e-324)', '5e-324'],
    ['(number->string 2.5e-10)', '0.00000000025'],
    ['(number->string 536870911.0)', '536870911.0'],
    ['(number->string 536870912.0)', '536870912.0'],
    ['(number->string -536870913.0)', '-536870913.0'],
]) {
    test('CONTROL ' + expr, () => {
        assert.deepEqual(evaluate(expr), { kind: 'answered', detail: want });
    });
}

// THE REFUSALS GET A TYPE CHECK RATHER THAN A PRINTED COMPARISON.
// display prints a string and a symbol without quoting, so comparing the
// output against "#f" would be satisfied by the STRING "#f" or by the
// symbol |#f| -- a repair that answered a sentinel instead of a boolean
// would read as correct.  These ask what the value IS.
for (const text of ['banana', '+inf', 'inf.0', '', '1/', '/2', '+', '1e', 'nan.0']) {
    test('CONTROL string->number refuses ' + JSON.stringify(text) + ', as a boolean', () => {
        const r = evaluate('(let ((v (string->number "' + text + '"))) '
                           + '(cond ((eq? v #f) (quote refused)) '
                           + '((number? v) (list (quote ACCEPTED) v)) '
                           + '(else (list (quote NOT-A-BOOLEAN) v))))');
        assert.deepEqual([r.kind, r.detail], ['answered', 'refused']);
    });
}

// THE WRITER IS ONE BRANCH WITH SEVERAL DOORS.  number->string, display
// and an exception's irritant all reach the same printer, so a repair
// applied to one spelling and not to the shared branch would leave the
// others emitting the placeholder.  These rows go through the other two
// doors for the same three values.
for (const [name, expr, want] of [
    ['display of +inf.0', '(with-output-to-string (lambda () (display +inf.0)))', '+inf.0'],
    ['display of -inf.0', '(with-output-to-string (lambda () (display -inf.0)))', '-inf.0'],
    ['display of +nan.0', '(with-output-to-string (lambda () (display +nan.0)))', '+nan.0'],
    ['write of +inf.0', '(with-output-to-string (lambda () (write +inf.0)))', '+inf.0'],
    // The irritant of a condition is printed by the same path, which is
    // how test/defect-exact-of-nan-never-returns.mjs came to pin the
    // placeholder: it asserts the message exact/inexact->exact produces.
    // When this goes green that cell's expectation has to move with it.
    ['an exception irritant naming an infinity',
     '(guard (e (#t (with-output-to-string (lambda () (display (car (condition-irritants e))))))) '
     + '(error (quote probe) "m" +inf.0))', '+inf.0'],
]) {
    test('writer: ' + name, () => {
        assert.deepEqual(evaluate(expr), { kind: 'answered', detail: want });
    });
}

// CONTROL for that group: the other doors already agree on an ordinary
// value, so a red above is about the infinity branch and not about the
// door.
for (const [expr, want] of [
    ['(with-output-to-string (lambda () (display -1.5)))', '-1.5'],
    ['(with-output-to-string (lambda () (write 1e300)))', '1e300'],
]) {
    test('CONTROL ' + expr.slice(0, 48), () => {
        assert.deepEqual(evaluate(expr), { kind: 'answered', detail: want });
    });
}
