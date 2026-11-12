// What the compiler refuses around locally bound keyword names (ledger R43),
// and the nearest things it accepts.
//
//   - A definition that a macro produces, or that sits inside a begin, binds
//     from where it stands, but is not renamed; if its name is a core form's
//     (if, let, quote ...) a later CALL of it in that body would be misread
//     by the passes after expansion, so that call is refused, by name, with
//     the way out: write the definition directly in the body.  The same
//     program with the definition written directly compiles and answers.
//   - A local variable named export is a variable: a call of it is checked
//     like any other call, so an excluded name inside is still refused.  It
//     used to be skipped as an export declaration.
//   - A top-level definition of a name the compiler does not honour as a
//     top-level variable -- a core or derived form's, an auxiliary's, apply,
//     a prelude macro's -- is refused at the definition, by name, once the
//     import no longer binds it: its uses would stay the keyword and the
//     program's definition would be ignored.  It used to be refused only
//     by accident, under another form's message, or not at all.  A name
//     whose top-level redefinition does take effect (list, call/cc) is
//     defined and called as before.
//   - An import that gives a VARIABLE the name of a form the compiler
//     dispatches on -- (rename (only (rnrs) list) (list begin)) -- is
//     refused where it is written, by name: after expansion a head so
//     spelled is the form, so a call of the variable could not be told
//     from the expander's own forms.  The same for the auxiliaries (else,
//     =>, unquote, unquote-splicing): a call of such a variable did reach
//     it, but in a cond clause or a quasiquote the spelling was still read
//     as the keyword.  A prefix that produces such a name is refused like a
//     rename.  Where the variable stays a variable in every position
//     (apply, call/cc) the import is accepted, as before.
import test from 'node:test';
import assert from 'node:assert/strict';
import { compileSource } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';

const compile = text => compileSource(text, { name: 'keyword-shadowing-refusals' });
const refusal = async text => {
    try { await compile(text); } catch (e) { return `${e.output ?? ''}${e.message}`; }
    return null;
};
const DECL = `(define-syntax decl-proc (syntax-rules () ((_ n) (define (n . args) (length args)))))\n`;

test('a call of a macro-produced definition named like a core form is refused', async () => {
    const said = await refusal(
        `(import (rnrs))\n${DECL}(display (let () (decl-proc if) (if 1 2 3 4)))\n`);
    assert.ok(said, 'the program compiled');
    assert.match(said, /\bif\b/);
    assert.match(said, /write the definition directly in the body/);
});

test('the same for a definition inside a begin', async () => {
    const said = await refusal(
        `(import (rnrs))\n(display (let () (begin (define (quote . args) (length args))) (quote 1 2)))\n`);
    assert.ok(said, 'the program compiled');
    assert.match(said, /quote/);
    assert.match(said, /write the definition directly in the body/);
});

test('a macro-produced definition of a name a local binding has renamed is refused', async () => {
    // references before the definition were already emitted for the outer
    // binding, so the definition cannot take the name over
    const said = await refusal(
        `(import (rnrs))\n(define-syntax decl (syntax-rules () ((_ n v) (define n v))))\n` +
        `(display (let ((if (lambda xs xs))) (let () (decl if 5) (+ if 1))))\n`);
    assert.ok(said, 'the program compiled');
    assert.match(said, /\bif\b/);
    assert.match(said, /write the definition directly in the body/);
});

test('written directly in the body, the definition is called', async () => {
    const bytes = await compile(
        `(import (rnrs))\n(display (let () (define (if . args) (length args)) (if 1 2 3 4)))\n`);
    assert.equal((await runModule(bytes)).text, '4');
});

test('a macro-produced definition of such a name used only as a value compiles', async () => {
    const bytes = await compile(
        `(import (rnrs))\n(define-syntax decl (syntax-rules () ((_ n v) (define n v))))\n` +
        `(display (let () (decl begin 5) (+ begin 1)))\n`);
    assert.equal((await runModule(bytes)).text, '6');
});

test('a call of a local variable named export does not hide an excluded name', async () => {
    const said = await refusal(
        `(import (except (rnrs) car))\n(display (let ((export (lambda (x) x))) (export (car '(1 2)))))\n`);
    assert.ok(said, 'the program compiled');
    assert.match(said, /car/);
});

// a top-level definition of NAME after the import excludes it (or, for a name
// (rnrs) does not export, with a plain import)
const topLevel = (name, exported, form, use) =>
    `(import ${exported ? `(except (rnrs) ${name})` : '(rnrs)'})\n${form}\n(display ${use})\n`;

for (const [name, exported, form, use] of [
    ['when', true, `(define (when a b) (list 'mine a b))`, `(when 1 2)`],
    ['and', true, `(define (and a b) (list 'mine a b))`, `(and 1 2)`],
    ['if', true, `(define (if . xs) (length xs))`, `(if 1 2 3 4)`],
    ['begin', true, `(define (begin . xs) (length xs))`, `(begin 10 20)`],
    ['quote', true, `(define (quote . xs) (length xs))`, `(quote 1 2)`],
    ['let', true, `(define (let . xs) (length xs))`, `(let 1 2)`],
    ['else', true, `(define else #f)`, `(cond (else 'kw) (#t 'mine))`],
    ['unquote', true, `(define (unquote x) 'mine)`, '`(1 ,(+ 1 2))'],
    ['apply', true, `(define (apply f xs) 'mine)`, `(apply car '((1)))`],
    ['assert', true, `(define (assert . xs) 'mine)`, `(assert #f)`],
    ['guard', true, `(define (guard . xs) 'mine)`, `(guard 1 2)`],
    ['not', false, `(define (not x) 'mine)`, `(not 1)`],
]) {
    test(`a top-level definition of ${name} is refused, by name`, async () => {
        const said = await refusal(topLevel(name, exported, form, use));
        assert.ok(said, 'the program compiled');
        assert.match(said, /choose another name/);
        assert.ok(said.includes(name), `the message does not name ${name}: ${said}`);
    });
}

for (const [name, form, use, want] of [
    ['list', `(define (list . xs) 'mine)`, `(list 1 2)`, 'mine'],
    ['vector', `(define (vector . xs) 'mine)`, `(vector 1 2)`, 'mine'],
    ['call/cc', `(define (call/cc f) 'mine)`, `(call/cc (lambda (k) 1))`, 'mine'],
]) {
    test(`a top-level definition of ${name} takes effect, as before`, async () => {
        const bytes = await compile(topLevel(name, true, form, use));
        assert.equal((await runModule(bytes)).text, want);
    });
}

test('the import rule still answers for a name the import binds', async () => {
    const said = await refusal(`(import (rnrs))\n(define (when a b) 1)\n(display 1)\n`);
    assert.ok(said, 'the program compiled');
    assert.match(said, /exclude it with except/);
});

// a variable (list) imported under NAME, the keyword of that name excluded
const aliased = name =>
    `(import (except (rnrs) ${name}) (rename (only (rnrs) list) (list ${name})))\n` +
    `(display (${name} 10 20))\n`;

for (const name of ['if', 'begin', 'set!', 'quote', 'when', 'and', 'let', 'lambda', 'cond', 'assert',
                    'else', '=>', 'unquote', 'unquote-splicing']) {
    test(`importing a variable under the name ${name} is refused, by name`, async () => {
        const said = await refusal(aliased(name));
        assert.ok(said, 'the program compiled');
        assert.match(said, /choose another name/);
        assert.ok(said.includes(name), `the message does not name ${name}: ${said}`);
    });
}

for (const name of ['apply', 'call/cc']) {
    test(`a variable imported under the name ${name} is that variable in every position`, async () => {
        const bytes = await compile(
            `(import (except (rnrs) ${name}) (rename (only (rnrs) list) (list ${name})))\n` +
            `(define (twice f) (f 1 2))\n` +
            `(display (list (${name} 10 20) (twice ${name}) (let ((g ${name})) (g 3))))\n`);
        assert.equal((await runModule(bytes)).text, '((10 20) (1 2) (3))');
    });
}

test('a prefix that gives a variable such a name is refused like a rename', async () => {
    const said = await refusal(
        `(library (m) (export f) (import (rnrs)) (define (f . xs) xs))\n` +
        `(import (except (rnrs) if) (prefix (m) i))\n(display (if 10 20))\n`);
    assert.ok(said, 'the program compiled');
    assert.match(said, /choose another name/);
});
