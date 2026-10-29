// A large quoted literal does not make the program's main function large.
//
// Quoted lists and vectors were built by code at the place they appear,
// so a program whose top level holds a large literal compiled to a main
// function as large as its data.  With a hot loop also at the top level,
// V8 tiers that whole function up, and its optimizing compiler spent
// seconds on it (test/zstd.ss: about 120 KB of main, 6 s on wasm against
// 0.1 s on JS; the decoder itself was not the cost).  A literal is now a
// constant built once, outside every function, so main holds only the
// program's own code.
//
// This reads SIZES, not time.  For a program whose top level defines a
// large literal list (20,000 elements; 1,500 for the self-hosted
// compiler) and loops over it, the LARGEST function body
// in the module stays far below the literal's size -- not only main's: a
// literal built by a helper function that main calls once would leave main
// small and still put the construction in a function, which is not what
// the change is.  Nor may the code as a whole grow with the literal: the
// code section of the program with the literal is within 4 KB of the
// control's, and neither has a start function, so construction split into
// many small functions, or run from a start function, fails too.  The
// literal's place is the global section, whose initializers build it.
// The control program, the same loop over a list built at
// run time, shows what the code needs without the literal.  The program
// is also run, and must print the sum the data gives, so a constant with
// the wrong contents does not pass on size alone.
//
// The other rows, each on both compilers:
//   - a literal in a function nothing calls or exports costs the module
//     nothing (only live literals are built);
//   - a literal reachable only from an exported function is built, and is
//     one object across calls from the host;
//   - the prepared shape of the identity cell's two paths: the inliner
//     copies lit-inlined's body to its call sites and leaves lit-kept's
//     calls in place (read with test/lib/literal-shape.sc, Chez-hosted),
//     so test/quoted-literal-is-one-object.ss reaches its constant by both.
//
// Each compile is a fresh compiler instance (one process for the
// Chez-hosted compiler, one instantiation of goeteia.wasm for the
// self-hosted one), so a table left over from an earlier compilation
// cannot reach a later one; the nested case, conjure bodies inside one
// compilation, is test/quoted-literal-is-one-object.ss's row 16.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// the byte length of the body of the function the module exports as
// main: the import count comes from the engine, and only the export and
// code sections are read here
function sizes(bytes) {
    const imported = WebAssembly.Module.imports(new WebAssembly.Module(bytes))
        .filter(i => i.kind === 'function').length;
    let p = 8;
    const u = () => { let r = 0, s = 0, x; do { x = bytes[p++]; r |= (x & 0x7f) << s; s += 7; } while (x & 0x80); return r >>> 0; };
    let mainIndex = -1, hasStart = false;
    const sizes = [];
    while (p < bytes.length) {
        const id = bytes[p++], len = u(), end = p + len;
        if (id === 8) hasStart = true;
        if (id === 7) {
            for (let n = u(), i = 0; i < n; i++) {
                const nl = u(); const name = Buffer.from(bytes.subarray(p, p + nl)).toString(); p += nl;
                const kind = bytes[p++]; const idx = u();
                if (kind === 0 && name === 'main') mainIndex = idx;
            }
        } else if (id === 10) {
            for (let n = u(), i = 0; i < n; i++) { const sz = u(); sizes.push(sz); p += sz; }
        }
        p = end;
    }
    assert.ok(mainIndex >= imported, 'the module exports no defined function named main');
    return { main: sizes[mainIndex - imported], largest: Math.max(...sizes), total: bytes.length,
             code: sizes.reduce((a, b) => a + b, 0), start: hasStart };
}

function compile(src, way) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-litmain-'));
    try {
        const ss = path.join(dir, 'p.ss'), out = path.join(dir, 'p.wasm');
        fs.writeFileSync(ss, src);
        const c = way === 'chez'
            ? spawnSync(path.join(root, 'bin/goeteiac'), [ss, out], { cwd: root, encoding: 'utf8', timeout: 300000 })
            : spawnSync('node', [path.join(root, 'rt/compile.mjs'), path.join(root, 'goeteia.wasm'), ss, out], { cwd: root, encoding: 'utf8', timeout: 300000 });
        assert.ok(c.status === 0 && fs.existsSync(out), `${way}: not compiled (status ${c.status}): ${((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop()}`);
        const bytes = fs.readFileSync(out);
        const run = spawnSync('node', [path.join(root, 'rt/run.mjs'), out], { cwd: root, encoding: 'utf8', timeout: 120000 });
        return { ...sizes(bytes), printed: (run.stdout || '').trim(), module: new WebAssembly.Module(bytes) };
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

// The self-hosted compiler recurses once per list element while reading
// the list and, before this change, while building it, and overflows
// node's default stack between 1,500 and 1,800 elements (the reader's
// limit is older than this change and recorded separately).  So it gets
// 1,500 elements and a bound to match: built inside a function they take
// 12,545 bytes there, the control program's largest function 3,629.
const SIZES = { chez: 20000, self: 1500 };
const BOUNDS = { chez: 16384, self: 6000 };
function program(n) {
    const values = Array.from({ length: n }, (_, i) => (i * 7919) % 256);
    let expect = 0;
    for (let k = 0; k < 50; k++) expect = (expect + values.reduce((a, b) => (a + b) & 65535, 0)) & 65535;
    return { items: values.join(' '), expect, n };
}
const loopText = `(define (sum l) (let walk ((l l) (s 0)) (if (null? l) s (walk (cdr l) (bitwise-and (+ s (car l)) 65535)))))
(let again ((k 0) (s 0)) (if (= k 50) (display s) (again (+ k 1) (bitwise-and (+ s (sum data)) 65535))))
`;
const withLiteral = p => `(import (rnrs))\n(define data '(${p.items}))\n${loopText}`;
// the control builds the same values in reverse order; the sum is the same
const control = p => `(import (rnrs))\n(define data (let build ((i 0) (acc '())) (if (= i ${p.n}) acc (build (+ i 1) (cons (mod (* i 7919) 256) acc)))))\n${loopText}`;

// a function nothing calls or exports, holding a literal of its own
const deadItems = Array.from({ length: 5000 }, (_, i) => (i * 31) % 256).join(' ');
const tiny = `(import (rnrs))\n(display 7)\n`;
const withDead = `(import (rnrs))\n(define (never) '(${deadItems}))\n(display 7)\n`;
// a literal reachable only through exports: the host calls h and hs
const exportedOnly = `(import (rnrs))
(define (h) '(5 6 7 8))
(define (hs) (let walk ((l (h)) (s 0)) (if (null? l) s (walk (cdr l) (+ s (car l))))))
(export h hs)
`;
function call(module, name) {
    const imports = {};
    for (const i of WebAssembly.Module.imports(module))
        if (i.kind === 'function') (imports[i.module] ||= {})[i.name] = () => 0;
    return new WebAssembly.Instance(module, imports).exports;
}

for (const way of ['chez', 'self']) {
    const prog = program(SIZES[way]), expect = prog.expect, BOUND = BOUNDS[way];
    test(`${way}: no function holds a ${prog.n}-element literal, and the program reads it right`, () => {
        const c = compile(control(prog), way);
        assert.ok(c.largest < BOUND, `CONTROL: the largest function without the literal is ${c.largest} bytes; the bound itself is wrong`);
        assert.equal(c.printed, String(expect), 'CONTROL: the control program computes another sum; the expectation is wrong');
        const s = compile(withLiteral(prog), way);
        assert.ok(s.largest < BOUND, `the largest function is ${s.largest} bytes with the literal (main ${s.main}; ${c.largest} without it): the literal is built inside a function`);
        assert.equal(s.printed, String(expect), 'the program reads other data than its literal holds');
        assert.ok(s.code - c.code < 4096,
                  `the code section grows by ${s.code - c.code} bytes with the literal: it is built by code, in some function`);
        assert.equal(s.start, c.start, 'a start function appears with the literal');
    });
    test(`${way}: a literal in dead code is not built`, () => {
        const t = compile(tiny, way), d = compile(withDead, way);
        assert.ok(d.total - t.total < 4096,
                  `a never-called function's 5000-element literal adds ${d.total - t.total} bytes to the module`);
    });
    test(`${way}: a literal reachable only through exports is built, and is one object`, () => {
        const e = compile(exportedOnly, way);
        const x = call(e.module);
        assert.equal(x.hs() >> 1, 26, 'the exported literal holds other values');
        assert.ok(x.h() === x.h(), 'the exported literal is a new object on each call');
    });
}

// The same two liveness rows on the JS target, compiled by the Chez-hosted
// compiler: the emitted module's text for the dead literal, and its xports
// (fixnums are tagged: n arrives as 2n) for the exported-only one.
function compileJs(src) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-litjs-'));
    const ss = path.join(dir, 'p.ss'), out = path.join(dir, 'p.mjs');
    fs.writeFileSync(ss, src);
    const c = spawnSync(path.join(root, 'bin/goeteiac'), ['--js', ss, out], { cwd: root, encoding: 'utf8', timeout: 300000 });
    assert.ok(c.status === 0 && fs.existsSync(out), `js: not compiled: ${((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop()}`);
    return { dir, out, size: fs.statSync(out).size };
}
test('js: a literal in dead code is not emitted', () => {
    const t = compileJs(tiny), d = compileJs(withDead);
    try {
        assert.ok(d.size - t.size < 4096, `a never-called function's 5000-element literal adds ${d.size - t.size} bytes to the JS module`);
    } finally { fs.rmSync(t.dir, { recursive: true, force: true }); fs.rmSync(d.dir, { recursive: true, force: true }); }
});
test('js: a literal reachable only through exports is built, and is one object', async () => {
    const e = compileJs(exportedOnly);
    try {
        const m = await import(e.out);
        m.main();
        assert.equal(m.xports.hs(), 52, 'the exported literal holds other values');
        assert.ok(m.xports.h() === m.xports.h(), 'the exported literal is a new object on each call');
    } finally { fs.rmSync(e.dir, { recursive: true, force: true }); }
});

test('the identity cell reaches its constant through an inlined call and a kept one', (t) => {
    const chez = spawnSync('chez', ['--version'], { encoding: 'utf8' });
    if (chez.status !== 0) {
        console.log('NOT EXERCISED HERE (no chez on PATH; the prepared-shape instrument is Chez-hosted and this reading was NOT taken)');
        return;
    }
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-litshape-'));
    try {
        // the two definitions of test/quoted-literal-is-one-object.ss rows 1
        // and 2, alone: the instrument loads the compiler directly, without
        // the driver, and cannot read that file's conjure bodies
        const fx = path.join(dir, 'shape.ss');
        fs.writeFileSync(fx, "(import (rnrs))\n(define (lit-inlined) '(1 2))\n(define (lit-kept) (let ((x '(1 2))) x))\n"
            + "(display (list (eq? (lit-inlined) (lit-inlined)) (eq? (lit-kept) (lit-kept))))\n");
        const r = spawnSync('chez', ['--script', path.join(root, 'test/lib/literal-shape.sc'), root, fx, 'lit-inlined', 'lit-kept'],
                            { cwd: root, encoding: 'utf8', timeout: 300000 });
        assert.equal((r.stdout || '').trim().split('\n').pop(), '(calls ((lit-inlined . 0) (lit-kept . 2)))',
                     `the prepared shape changed: ${(r.stdout || '') + (r.stderr || '')}`);
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
