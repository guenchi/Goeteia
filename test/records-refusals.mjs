// What the compiler refuses in a record definition (ledger R74), with the
// nearest thing it accepts beside each refusal.
//
// Before the change define-record-type read its `fields` clause and dropped
// every other clause without a word, so each program here compiled -- to a
// type that was not the one written.  Now a clause the compiler does not
// implement, or cannot honour, is refused where it stands, by name:
//   - an unknown clause; a clause given twice; parent-rtd (the procedural
//     layer is not there yet); a sealed or opaque value that is not #t or #f;
//     two fields of one name;
//   - a parent that is sealed; a parent that is a variable but not a record
//     type; a parent that is not bound at all;
//   - a type without a protocol whose parent has one (R6RS 6.2);
//   - a second definition with the uid of the first and another shape;
//   - the record name defined a second time: it is a binding now;
//   - (record-type-descriptor x) of something that is not a record type.
// A protocol expression that does not give a procedure is found when the
// definition runs: the program stops with the uncaught report.
//
// The compiler here is the self-hosted one (rt/compile.mjs); run-tests.sh
// puts the same refusals through the Chez-hosted compiler by compiling
// test/records-*.ss on both.
import test from 'node:test';
import assert from 'node:assert/strict';
import { compileSource } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';

const compile = text => compileSource(text, { name: 'records-refusals' });
const refusal = async text => {
    try { await compile(text); } catch (e) { return `${e.output ?? ''}${e.message}`; }
    return null;
};
const P = '(import (rnrs))\n';
const POINT = '(define-record-type point (fields x y))\n';

const refused = [
    ['an unknown clause', `${P}(define-record-type p (fields x) (colour red))\n`, /colour/],
    ['the fields clause twice', `${P}(define-record-type p (fields x) (fields y))\n`, /fields/],
    ['the parent clause twice', `${P}${POINT}(define-record-type p (parent point) (parent point))\n`, /parent/],
    ['parent-rtd', `${P}${POINT}(define-record-type p (parent-rtd (record-type-descriptor point) #f) (fields z))\n`, /parent-rtd/],
    ['a sealed value that is not a boolean', `${P}(define-record-type p (fields x) (sealed 5))\n`, /sealed/],
    ['an opaque value that is an expression', `${P}(define yes #t)\n(define-record-type p (fields x) (opaque yes))\n`, /opaque/],
    ['two fields of one name', `${P}(define-record-type p (fields x (mutable x)))\n`, /\bx\b/],
    ['a sealed parent', `${P}(define-record-type s (fields a) (sealed #t))\n(define-record-type c (parent s) (fields b))\n`, /sealed/],
    ['a parent that is a variable, not a record type', `${P}(define v 5)\n(define-record-type c (parent v) (fields b))\n`, /record type/],
    ['a parent that is not bound', `${P}(define-record-type c (parent nowhere) (fields b))\n`, /nowhere/],
    ['a parent defined later', `${P}(define-record-type c (parent later) (fields b))\n(define-record-type later (fields a))\n`, /later/],
    ['no protocol over a parent with one',
     `${P}(define-record-type a (fields x) (protocol (lambda (new) (lambda () (new 0)))))\n(define-record-type b (parent a) (fields y))\n`, /protocol/],
    ['one uid, another field name',
     `${P}(define-record-type a (fields x) (nongenerative u-1))\n(define-record-type b (fields y) (nongenerative u-1))\n`, /u-1/],
    ['one uid, another mutability',
     `${P}(define-record-type a (fields x) (nongenerative u-2))\n(define-record-type b (fields (mutable x)) (nongenerative u-2))\n`, /u-2/],
    ['one uid, another parent',
     `${P}${POINT}(define-record-type a (fields x) (nongenerative u-3))\n(define-record-type b (parent point) (fields x) (nongenerative u-3))\n`, /u-3/],
    ['one uid, sealed in one definition only',
     `${P}(define-record-type a (fields x) (nongenerative u-4))\n(define-record-type b (fields x) (nongenerative u-4) (sealed #t))\n`, /u-4/],
    ['the record name defined again as a variable', `${P}${POINT}(define point 5)\n`, /point/],
    ['the record name defined again as a record', `${P}${POINT}(define-record-type (point mk pt?) (fields q))\n`, /point/],
    ['a record named like an import', `${P}(define-record-type list (fields a))\n`, /list/],
    ['record-type-descriptor of a variable', `${P}(define v 5)\n(display (record-type-descriptor v))\n`, /record type/],
    ['record-type-descriptor of nothing bound', `${P}(display (record-type-descriptor nowhere))\n`, /nowhere/],
];
for (const [name, text, said] of refused) {
    test(`refused: ${name}`, async () => {
        const out = await refusal(text);
        assert.ok(out, `the program compiled:\n${text}`);
        assert.match(out, said, `the refusal does not name it:\n${out}`);
    });
}

// the nearest accepted things
const accepted = [
    ['sealed and opaque written #f', `${P}(define-record-type p (fields x) (sealed #f) (opaque #f))\n(display (p-x (make-p 4)))\n`, '4'],
    ['a literal (protocol #f) is no protocol', `${P}(define-record-type p (fields x) (protocol #f))\n(display (p-x (make-p 6)))\n`, '6'],
    ['a child of a type whose (protocol #f) is no protocol',
     `${P}(define-record-type a (fields x) (protocol #f))\n(define-record-type b (parent a) (fields y))\n(display (b-y (make-b 1 2)))\n`, '2'],
    ['one uid, the same shape, another protocol',
     `${P}(define-record-type a (fields x) (nongenerative u-9))\n` +
     `(define-record-type (b make-b b?) (fields (immutable x b-x)) (nongenerative u-9) (protocol (lambda (new) (lambda () (new 7)))))\n` +
     `(display (list (a? (make-b)) (b? (make-a 1)) (a-x (make-b))))\n`, '(#t #t 7)'],
    // the constructor and the predicate are named so that only `list` meets an import
    ['a record named like an import the program excludes',
     `(import (except (rnrs) list))\n(define-record-type (list make-my-list my-list?) (fields a))\n(display (list-a (make-my-list 3)))\n`, '3'],
    ['a local variable spelled like a record name', `${P}${POINT}(display (let ((point 5)) (+ point (point-x (make-point 1 2)))))\n`, '6'],
];
for (const [name, text, want] of accepted) {
    test(`accepted: ${name}`, async () => {
        const bytes = await compile(text);
        assert.equal((await runModule(bytes)).text, want);
    });
}

test('a protocol expression that does not give a procedure stops the program when the definition runs', async () => {
    const bytes = await compile(`${P}(define not-a-protocol 5)\n(display "before")\n(define-record-type p (fields x) (protocol not-a-protocol))\n(display "after")\n`);
    let text = '';
    try { text = (await runModule(bytes)).text; } catch (e) { text = `${e.output ?? ''}${e.message}`; }
    assert.match(text, /before/);
    assert.doesNotMatch(text, /after/);
    assert.match(text, /unhandled exception: .*protocol/);
});
