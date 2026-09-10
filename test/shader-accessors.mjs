// Every library that carries shader source must hand it out.
//
// The shaders in this tree are only as checkable as they are reachable.
// tools/cdp.mjs can put one in front of a real GLSL compiler, but only
// if something outside the library can get hold of it, and for most of
// this tree's shaders the forms were private constants: fifteen of them
// across five libraries, unreachable, and so never compiled by
// anything at all.  The recording context in rt/verify.mjs did not
// compile them either -- its compileShader did nothing and its
// getShaderParameter answered true -- and although a page's shaders
// now go in front of a real compiler, that only reaches shaders a page
// actually links.  A private constant no page reaches is still
// compiled by nothing, which is what this guard is about.
//
// So each such library exports a `*-shaders` accessor, and this is the
// guard on that list -- because a list of names does not shout when a
// name is missing from it.
//
// WHAT THIS GUARD CAN AND CANNOT SEE.  It works at the level of
// libraries, not shaders: it finds every library whose source contains
// shader declaration forms and insists that library exports an
// accessor.  It therefore catches a NEW LIBRARY that grows a shader and
// no accessor.  It does NOT catch a new shader added inside a library
// that already has an accessor, and it cannot: a shader built at its
// use site -- (gfx scene) composes two of them by transforming other
// libraries' forms -- is the value of no top-level definition, so
// nothing structural can enumerate it.  Those got into the accessors
// because a person read the use sites.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import assert from 'node:assert';

const root = new URL('..', import.meta.url).pathname;
const libs = [];
for (const fam of readdirSync(join(root, 'lib'))) {
    const dir = join(root, 'lib', fam);
    let files;
    try { files = readdirSync(dir); } catch { continue; }
    for (const f of files) {
        if (!f.endsWith('.ss')) continue;
        libs.push({ name: `(${fam} ${f.slice(0, -3)})`, path: join(dir, f),
                    src: readFileSync(join(dir, f), 'utf8') });
    }
}
assert.ok(libs.length > 20, 'the library sweep found almost nothing; the paths are wrong');

// A shader is a thing with a main.  The first draft of this looked for
// declaration forms -- (uniform ...), (attribute ...) -- and dragged in
// (gfx glsl) and (gfx wgsl), which contain those words because they are
// the languages rather than users of them.  Adding two names to an
// exception list is how a checker starts to rust; the sharper criterion
// has no exceptions at all, and picks out exactly the seven libraries
// that hold shader source.
//
// Comments are stripped first, so that a library which merely talks
// about a main in prose is not dragged in either.
const strip = s => s.split('\n').map(l => l.replace(/;.*$/, '')).join('\n');
const carriesShader = s => /\(define\s+\(main\)\s+void/.test(strip(s));
const exportsAccessor = s => /-shaders\b/.test(s);

test('every library that carries shader source hands it out', () => {
    const missing = libs.filter(l => carriesShader(l.src) && !exportsAccessor(l.src))
                        .map(l => l.name);
    assert.deepStrictEqual(missing, [],
        `these libraries contain shader forms but export no accessor:\n  ${missing.join('\n  ')}\n` +
        'add one shaped ((name dialect vertex-forms fragment-forms) ...), or, if the ' +
        'forms are not a whole shader on their own, say so in a comment where they are.');
});

test('and the guard would say so if one did not', () => {
    // the check applied to a library that plainly has forms and no
    // accessor: if this passes as "fine", the check above proves nothing
    const pretend = '(library (gfx nope)\n  (export draw!)\n  (define shader \'((define (main) void (set! gl_Position p)))))';
    assert.ok(carriesShader(pretend) && !exportsAccessor(pretend));
});

test('prose about a main does not count as carrying a shader', () => {
    const commented = '(library (gfx talk)\n  (export f)\n  ;; every shader has a (define (main) void ...)\n  (define (f) 1))';
    assert.ok(!carriesShader(commented));
});

test('the languages themselves are not dragged in', () => {
    // (gfx glsl) and (gfx wgsl) contain every one of those words, being
    // the printers for them; if this ever fails the criterion has
    // drifted back to matching declaration forms
    for (const name of ['(gfx glsl)', '(gfx wgsl)']) {
        const lib = libs.find(l => l.name === name);
        assert.ok(lib, `${name} is not in the sweep`);
        assert.ok(!carriesShader(lib.src), `${name} was taken for a shader library`);
    }
});
