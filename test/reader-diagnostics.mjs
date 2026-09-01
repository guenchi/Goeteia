// The diagnostics a user actually meets: what rt/compile.mjs prints
// when the self-hosted compiler (goeteia.wasm) refuses a source file.
// Both the exit status and the text on stderr are part of the
// contract -- a build script reads the first, a human reads the
// second.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import url from 'node:url';

const here = path.dirname(url.fileURLToPath(import.meta.url));
const compileMjs = path.join(here, '../rt/compile.mjs');
const compilerWasm = path.join(here, '../goeteia.wasm');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-readerdiag-'));

// compile source with the self-hosted compiler; return { status, stderr }.
// opts.js selects the JavaScript target, which reaches a different
// backend and so needs its own evidence.
function compile(name, source, opts = {}) {
    const src = path.join(tmp, name);
    fs.writeFileSync(src, source);
    const out = path.join(tmp, opts.js ? 'out.js' : 'out.wasm');
    const args = opts.js ? ['--js'] : [];
    try {
        execFileSync(process.execPath,
                     [compileMjs, ...args, compilerWasm, src, out],
                     { stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
        return { status: e.status, stderr: String(e.stderr) };
    }
    return { status: 0, stderr: '' };
}

// Compile with the CHEZ-HOSTED driver instead of the self-hosted one.
// Both exist, both report errors, and until this was written nothing
// compared what they say.  That gap is why a message could read
// "unbound variable elf-3" under one host and "unbound variable ~s
// elf-3" under the other for as long as it did: each host's output was
// plausible on its own, and no cell ever put them side by side.
function compileHosted(name, source) {
    const src = path.join(tmp, name);
    fs.writeFileSync(src, source);
    const out = path.join(tmp, 'hosted.wasm');
    try {
        execFileSync(path.join(here, '../bin/goeteiac'), [src, out],
                     { stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
        return { status: e.status, stderr: String(e.stderr) };
    }
    return { status: 0, stderr: '' };
}

// Each host wraps the diagnostic in its own prefix -- the driver says
// "Exception in", the runtime says "unhandled exception:" -- so the
// comparison is of the message BODY, which is the part the compiler
// wrote and the part that has to agree.
function messageBody(stderr) {
    const line = String(stderr).split('\n').find(l => /goeteia/.test(l)) || '';
    return line.replace(/^.*?goeteia:?\s*/, '').trim();
}

test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

// COMPILER diagnostics only.  The Chez-hosted driver reads source with
// CHEZ's reader, so a malformed literal is refused before any goeteia
// code sees it and the two hosts say different things by construction:
//
//   #q1  hosted:      invalid sharp-sign prefix #q at char 22 of #<input port ...>
//        self-hosted: unrecognised # syntax: #q at FILE line 2 column 11
//
// That is not a disagreement to fix -- they are two different readers,
// and the self-hosted one is the more useful of the two here.  Reader
// diagnostics are held against Chez by test/number-face.ss and the
// reader suites; what these cells hold is the part both hosts really
// do share, which is everything after the source has been read.
for (const [what, source] of [
        ['an unbound variable', '(display elf-3)'],
        ['an unbound call', '(nosuchfn 1)'],
        ['a set! on a number', '(set! 5 1)'],
        ['a bad argument count', '(car)']]) {
    test(`both hosts word ${what} identically`, () => {
        const a = compileHosted(`two-${what.replace(/ /g, '-')}.ss`,
                                `;; expect: 0\n${source}\n`);
        const b = compile(`two-b-${what.replace(/ /g, '-')}.ss`,
                          `;; expect: 0\n${source}\n`);
        assert.notEqual(a.status, 0, 'the Chez-hosted driver accepted it');
        assert.notEqual(b.status, 0, 'the self-hosted compiler accepted it');
        assert.equal(messageBody(a.stderr), messageBody(b.stderr));
        // and neither shows a format directive
        assert.doesNotMatch(a.stderr, /~[sad]/);
        assert.doesNotMatch(b.stderr, /~[sad]/);
    });
}

// These three used to assert a HINT: the reader had no exponent
// notation, so `1e-3` became a symbol, and an "unbound variable"
// message was so misleading that the compiler appended "exponent
// literals are not supported by this reader -- write the constant
// out".  The reader takes exponents now, so the hint would be a false
// statement and it is gone; what is asserted here instead is the thing
// the hint was apologising for.
//
// The hint lived in TWO backends, and only the JS test said so.  That
// is why a test named for a target is worth its duplication: removing
// it from src/compiler.ss alone left src/js-backend.ss calling a
// procedure that no longer existed, and the bootstrap said so at once.
test('an exponent literal compiles as a number', () => {
    const { status, stderr } = compile('exponent.ss',
        ';; expect: 0\n(define eps 1e-3)\n(display eps)\n');
    assert.equal(status, 0, `expected a clean compile, got: ${stderr}`);
});

// set! on something that is not a name at all used to report "set! of
// unbound variable 25000000.0" -- which classifies the fault wrongly.
// The target is not a variable that happens to be unbound; it is not a
// variable.  A maintainer reading "unbound" goes looking for a missing
// definition, and there is none to find.
//
// The distinction matters more since the reader took exponent
// notation: `2.5E+7` used to be a symbol, so "unbound variable" was
// accurate for it, and it silently stopped being accurate when the
// literal became a number.
for (const [what, source] of [['a numeric literal', '(set! 2.5E+7 1)'],
                              ['a string', '(set! "s" 1)'],
                              ['a boolean', '(set! #t 1)']]) {
    test(`set! of ${what} says the target is not an identifier`, () => {
        const { status, stderr } = compile(`set-${what.replace(/ /g, '-')}.ss`,
            `;; expect: 0\n${source}\n`);
        assert.notEqual(status, 0);
        assert.match(stderr, /set! target/);
        assert.match(stderr, /identifier/);
        // and NOT the wrong classification
        assert.doesNotMatch(stderr, /unbound/);
    });

    test(`the JS target says the same for ${what}`, () => {
        const { status, stderr } = compile(`set-js-${what.replace(/ /g, '-')}.ss`,
            `;; expect: 0\n${source}\n`, { js: true });
        assert.notEqual(status, 0);
        assert.match(stderr, /set! target/);
        assert.doesNotMatch(stderr, /unbound/);
    });
}

// Compiler messages carried an unsubstituted `~s` for their whole
// life: errorf stores the text and the irritants separately and the
// printer writes the text verbatim, so every one of them showed the
// directive to the user.  A format hole that nothing fills reads as
// the tool being broken.
//
// Two things have to hold together, which is why these are two
// assertions and not one: the directive is GONE, and the irritant it
// was standing in for is STILL THERE.  Dropping the text would satisfy
// the first on its own.
for (const [what, source, irritant] of [
        ['an unbound variable', '(display elf-3)', 'elf-3'],
        ['an unbound call', '(nosuchfn 1)', 'nosuchfn'],
        ['a set! on a number', '(set! 5 1)', '5']]) {
    test(`the message for ${what} has no format directive and keeps its irritant`, () => {
        const { status, stderr } = compile(
            `fmt-${what.replace(/ /g, '-')}.ss`, `;; expect: 0\n${source}\n`);
        assert.notEqual(status, 0);
        assert.doesNotMatch(stderr, /~[sad]/);
        assert.ok(stderr.includes(irritant),
                  `the irritant ${irritant} is missing from: ${stderr}`);
    });
}

test('the JS backend messages carry no directive either', () => {
    const { status, stderr } = compile('fmt-js.ss',
        ';; expect: 0\n(display elf-3)\n', { js: true });
    assert.notEqual(status, 0);
    assert.doesNotMatch(stderr, /~[sad]/);
    assert.ok(stderr.includes('elf-3'));
});

// The Chez-hosted driver decodes source as UTF-8 now, and two inputs
// have to be refused by name rather than mangled.  Both are on that
// host only -- the self-hosted reader takes source as bytes and never
// decodes -- so they go through the hosted compiler.
test('a source file that is not valid UTF-8 is refused by name', () => {
    const src = path.join(tmp, 'badbytes.ss');
    // a lone 0xFF, which no UTF-8 sequence can contain
    fs.writeFileSync(src, Buffer.concat([
        Buffer.from(';; expect: 0\n(define e "a'), Buffer.from([0xff]),
        Buffer.from('b")\n')]));
    const out = path.join(tmp, 'badbytes.wasm');
    let status = 0, stderr = '';
    try {
        execFileSync(path.join(here, '../bin/goeteiac'), [src, out],
                     { stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) { status = e.status; stderr = String(e.stderr); }
    assert.notEqual(status, 0);
    assert.match(stderr, /not valid UTF-8/);
    // and NOT the silent substitution the default decoder would do:
    // U+FFFD in the output would mean a corrupt file compiled
    assert.doesNotMatch(stderr, /\uFFFD/);
});

// The start line the hosted driver records for each top-level form.
// It reaches diagnostics through %loc markers and surfaces only from a
// runtime trap, so it had no observable path and was wrong in five
// ways at once -- newlines inside strings and inside line comments
// were not counted, parens inside block comments and inside |bar
// symbols| were counted, and `#;` was read as a line comment.  These
// are those five, plus the baseline they all shifted.
for (const [what, source, want] of [
        ['a form after a line comment',
         ';; c\n(define a 1)\n; comment\n(define b 2)\n', ['2', '4']],
        ['a form after a string holding a newline',
         ';; c\n(display "a\nb")\n(define b 2)\n', ['2', '3']],
        ['a form after a block comment holding a paren',
         ';; c\n#| ( |#\n(define b 2)\n', ['3']],
        ['a form after a bar symbol holding a paren',
         ';; c\n(list (quote |(|))\n(define b 2)\n', ['2', '3']],
        ['a form after a datum comment',
         ';; c\n#;(ignored) (define b 2)\n', ['2']]]) {
    test(`--dump-lines: ${what}`, () => {
        const src = path.join(tmp, `lines-${want.join('-')}-${want.length}.ss`);
        fs.writeFileSync(src, source);
        const out = execFileSync(path.join(here, '../bin/goeteiac'),
                                 ['--dump-lines', src],
                                 { stdio: ['ignore', 'pipe', 'pipe'] });
        const got = String(out).trim().split('\n').map(l => l.split(' ')[0]);
        assert.deepEqual(got, want);
    });
}

test('both hosts refuse a non-UTF-8 source with the same words', () => {
    // The hosted driver decodes source as UTF-8 and refuses what is not;
    // the self-hosted path read the bytes straight through and compiled
    // the file happily.  The two hosts may differ about many things but
    // not about WHICH PROGRAMS EXIST, so this pins that they refuse the
    // same file -- and with the same sentence, so the agreement cannot
    // rot into two wordings that both look right.
    const src = path.join(tmp, 'utf8-both.ss');
    fs.writeFileSync(src, Buffer.concat([
        Buffer.from(';; expect: 0\n(define e "a'), Buffer.from([0xff]),
        Buffer.from('b")\n')]));
    const out = path.join(tmp, 'utf8-both.wasm');
    const run = (cmd, args) => {
        try { execFileSync(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] }); }
        catch (e) { return String(e.stdout || '') + String(e.stderr || ''); }
        return '';
    };
    const hosted = run(path.join(here, '../bin/goeteiac'), [src, out]);
    const selfHosted = run(process.execPath, [compileMjs, compilerWasm, src, out]);
    const line = t => (t.match(/this source file is not valid UTF-8: .*/) || [''])[0];
    assert.ok(line(hosted), `the hosted driver accepted it: ${hosted}`);
    assert.ok(line(selfHosted), `the self-hosted compiler accepted it: ${selfHosted}`);
    assert.equal(line(hosted), line(selfHosted));
});

test('a character literal above U+007F is refused by name', () => {
    // The decoded reading makes #\<non-ascii> a single character on this
    // host, which the self-hosted reader has no spelling for.  Refusing
    // keeps the two hosts answering alike instead of adding a form to
    // one of them; before the decode it failed on both hosts with two
    // different messages.
    const r = compileHosted('bigchar.ss',
        ';; expect: 0\n(display (char->integer #\\\u03bb))\n');
    assert.notEqual(r.status, 0);
    assert.match(r.stderr, /U\+007F/);
});

test('set! of a name that IS a variable but unbound still says unbound', () => {
    // the should-GREEN half: narrowing the message must not swallow
    // the case it was carved out of
    const { status, stderr } = compile('set-unbound.ss',
        ';; expect: 0\n(set! elf-3 1)\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /unbound variable/);
    assert.match(stderr, /elf-3/);
});

test('an unbound ordinary name is still named', () => {
    const { status, stderr } = compile('ordinary.ss',
        ';; expect: 0\n(display elf-3)\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /unbound variable/);
    assert.match(stderr, /elf-3/);
});

test('the JS target reads exponents too', () => {
    // --js reaches a second backend with its own copy of this code
    // path; a fix only the wasm backend has is half a fix
    const { status, stderr } = compile('exponent-js.ss',
        ';; expect: 0\n(define eps 1e-3)\n(display eps)\n', { js: true });
    assert.equal(status, 0, `expected a clean compile, got: ${stderr}`);
});

test('the JS target still names an unbound ordinary name', () => {
    const { status, stderr } = compile('ordinary-js.ss',
        ';; expect: 0\n(display elf-3)\n', { js: true });
    assert.notEqual(status, 0);
    assert.match(stderr, /unbound variable/);
    assert.match(stderr, /elf-3/);
});

// The compiler is fed one stream holding the prelude, the runtime
// glue and every resolved import ahead of the user's source, so the
// reader's raw line is some four-figure stream line.  The (%loc ...)
// markers the driver plants map it back, and these tests pin the
// mapping: the number a user reads must be the line in the file the
// user wrote, with that file named.
test('an unclosed list names the file and the true source line', () => {
    const { status, stderr } = compile('unclosed.ss',
        ';; expect: 0\n(define (f x)\n  (+ x\n     1)\n(display (f 1))\n');
    assert.notEqual(status, 0);
    // (define opens on line 2, at column 1, of a five-line file
    assert.match(stderr,
                 /list opened at \S*unclosed\.ss line 2 column 1 never closed/);
});

test('a close paren with nothing open is reported, not looped on', () => {
    // before positions existed this fell through to the atom reader,
    // which consumed nothing and left the driver spinning
    const { status, stderr } = compile('stray.ss',
        ';; expect: 0\n(display 1))\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /unexpected \) at \S*stray\.ss line 2 column 12/);
});

test('an unclosed string names its open quote', () => {
    const { status, stderr } = compile('unstring.ss',
        ';; expect: 0\n(display "hello)\n');
    assert.notEqual(status, 0);
    assert.match(stderr,
                 /string opened at \S*unstring\.ss line 2 column 10 never closed/);
});

test('the mapped line tracks a mistake further down the file', () => {
    // one origin for the whole file would satisfy the test above by
    // accident; a mistake on line 6 must report 6, not 2
    const { status, stderr } = compile('deep.ss',
        ';; expect: 0\n(define a 1)\n(define b 2)\n(define c 3)\n'
        + '(define d 4)\n(display (+ a\n');
    assert.notEqual(status, 0);
    assert.match(stderr, /list opened at \S*deep\.ss line 6 column 10 never closed/);
});
