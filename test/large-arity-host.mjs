// What a host sees of procedures and calls at the 1000-parameter limit
// (ledger R50b).  A WebAssembly function type takes at most 1000
// parameters; from 1000 fixed parameters on, a procedure takes its
// arguments as a list and has no positional signature to export.
//
//   - an exported procedure of 999 parameters, and one of 999 fixed
//     parameters and a rest, are called positionally from the host and
//     answer -- as before the change;
//   - two exported procedures of 256 parameters in one optimised module,
//     one only ever called with flonums and one with booleans, keep the
//     parameter representation the optimiser gave each: each takes its own
//     and refuses the other's -- as before the change;
//   - exporting a procedure of 1000 fixed parameters, with or without a
//     rest, is refused when the module is compiled, by name; on the
//     JavaScript target, which has no such limit, it still compiles;
//   - a direct call of such a procedure with the wrong number of arguments
//     is the compile-time error it is for a small one;
//   - the self-hosted compiler, at the default stack, compiles a call of
//     `list' with 20,000 arguments and an `apply' with 20,000 leading
//     arguments, and both run.
//
// BEFORE THE CHANGE the two refusals compile (the module then fails to
// instantiate) and the 20,000-argument programs do not get as far as running.
import test from 'node:test';
import assert from 'node:assert/strict';
import { compileSource } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';

const names = n => Array.from({ length: n }, (_, i) => `a${i}`).join(' ');
const nums = n => Array.from({ length: n }, (_, i) => String(i)).join(' ');
const fix = v => v * 2;                       // a fixnum as the host passes it

function instantiate(bytes) {
    const m = new WebAssembly.Module(bytes), imports = {};
    for (const x of WebAssembly.Module.imports(m))
        if (x.kind === 'function') (imports[x.module] ??= {})[x.name] = () => 0;
    const ex = new WebAssembly.Instance(m, imports).exports;
    ex.main();
    return ex;
}
const compile = (text, opts = {}) => compileSource(text, { name: 'large-arity-host', ...opts });
const refusal = async text => {
    try { await compile(text); } catch (e) { return `${e.output ?? ''}${e.message}`; }
    return null;
};

test('an export of 999 parameters is called positionally', async () => {
    const ex = instantiate(await compile(
        `(import (rnrs))\n(define (f ${names(999)}) (+ a0 a998))\n(export f)\n`));
    assert.equal(ex.f(...Array.from({ length: 999 }, (_, i) => fix(i))), fix(998));
});

test('an export of 999 fixed parameters and a rest is called positionally', async () => {
    const ex = instantiate(await compile(
        `(import (rnrs))\n(define (g ${names(999)} . r) (+ a998 (length r)))\n(export g)\n`));
    assert.equal(ex.g(...Array.from({ length: 999 }, (_, i) => fix(i)), ex.null.value), fix(998));
});

test('an optimised export keeps the representation of its parameters', async () => {
    const def = name => `(define (${name} ${names(256)}) (if a0 #t (${name} ${names(256)})))`;
    const ex = instantiate(await compile(
        `(import (rnrs))\n${def('f')}\n${def('g')}\n` +
        `(f ${Array(256).fill('1.5').join(' ')})\n(g ${Array(256).fill('#t').join(' ')})\n(export f g)\n`));
    const yes = ex.true.value;
    assert.equal(ex.f(...Array(256).fill(1.25)), yes, 'f takes raw numbers');
    assert.equal(ex.g(...Array(256).fill(yes)), yes, 'g takes Scheme values');
    assert.throws(() => ex.f(...Array(256).fill(yes)), TypeError, 'f refuses Scheme values');
    assert.throws(() => ex.g(...Array(256).fill(1.25)), TypeError, 'g refuses raw numbers');
});

test('exporting a procedure of 1000 fixed parameters is refused by name', async () => {
    const said = await refusal(
        `(import (rnrs))\n(define (big ${names(1000)}) a0)\n(export big)\n`);
    assert.ok(said, 'the module compiled');
    assert.match(said, /big/);
    assert.match(said, /1000/);
});

test('exporting one of 1000 fixed parameters and a rest is refused by name', async () => {
    const said = await refusal(
        `(import (rnrs))\n(define (bigrest ${names(1000)} . r) a0)\n(export bigrest)\n`);
    assert.ok(said, 'the module compiled');
    assert.match(said, /bigrest/);
});

test('the JavaScript target still exports a procedure of 1000 parameters', async () => {
    const text = await compile(
        `(import (rnrs))\n(define (big ${names(1000)}) a0)\n(export big)\n`, { target: 'js' });
    assert.ok(text.length > 0);
});

test('a direct call with the wrong count is a compile-time error', async () => {
    const said = await refusal(
        `(import (rnrs))\n(define (big ${names(1000)}) a0)\n(display (big ${nums(999)}))\n`);
    assert.ok(said, 'the module compiled');
    assert.match(said, /wrong argument count/);
    const few = await refusal(
        `(import (rnrs))\n(define (bigrest ${names(1000)} . r) a0)\n(display (bigrest ${nums(999)}))\n`);
    assert.ok(few, 'the module compiled');
    assert.match(few, /too few arguments/);
});

test('a call of list with 20,000 arguments compiles and runs', async () => {
    const bytes = await compile(
        `(import (rnrs))\n(define (run) (length (list ${nums(20000)})))\n(display (run))\n`);
    assert.equal((await runModule(bytes)).text, '20000');
});

test('an apply with 20,000 leading arguments compiles and runs', async () => {
    const bytes = await compile(
        `(import (rnrs))\n(define (count . xs) (length xs))\n` +
        `(define (run) (apply count ${nums(20000)} '(x y)))\n(display (run))\n`);
    assert.equal((await runModule(bytes)).text, '20002');
});
