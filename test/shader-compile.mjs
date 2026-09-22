// Every shader this tree can emit, put in front of a real GLSL compiler.
//
// Nothing else here does that.  rt/verify.mjs's GL is a recording stub
// -- compileShader does nothing, getShaderParameter answers true -- so
// an invalid shader passes every page test with draws counted and
// frames animated.  Two defects fixed the day this was written, a
// negative literal printing as the decrement operator and a malformed
// float literal, were both invisible to the whole suite and both are
// refused by a real compiler with a line number.
//
// The shaders come from the libraries' own accessors, via
// tools/shader-emit.ss, and not from a list kept here: a list here would
// be a second place to add a shader to, and the one that gets forgotten
// is always the second one.
//
// This stands down rather than failing when no browser is present.  The
// announcement goes through the same channel as every other stand-down
// in this suite, so it appears in the run's summary instead of passing
// in silence.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import assert from 'node:assert';
import { findChrome, withBrowser, checkShader, NoBrowser } from '../tools/cdp.mjs';
import { emitAll } from '../tools/shader-emit.mjs';

const root = new URL('..', import.meta.url).pathname;

// A fragment shader for the vertex-only entries and a vertex shader for
// the fragment-only ones.  Pairing is the caller's job -- the library
// offers one half because the other half is the caller's -- so the test
// plays the caller.
const PAIR = {
    es100: {
        vs: 'attribute vec2 a_pos; void main(){ gl_Position = vec4(a_pos, 0.0, 1.0); }',
        fs: 'precision mediump float; void main(){ gl_FragColor = vec4(1.0); }',
    },
    es300: {
        vs: '#version 300 es\nin vec2 a_pos; void main(){ gl_Position = vec4(a_pos, 0.0, 1.0); }',
        fs: '#version 300 es\nprecision mediump float; out vec4 o; void main(){ o = vec4(1.0); }',
    },
};

// THIS ONE NEEDS NO BROWSER, so it is not inside the branch below.  It
// sat there until it was noticed that a machine without Chrome skipped
// the registration question too -- and that question is about a list in
// a file, which no GPU has an opinion about.  A check that stands down
// for a reason that does not apply to it is a check that is absent
// wherever the reason is true.
test('every library that emits shaders is named in the emitter', () => {
    // The emitter is a list of names, and a list of names cannot shout
    // for what is missing from it.  Two libraries landed shader
    // functions and neither was added, so a real GLSL compiler had
    // never read either one -- they were strings nobody had checked.
    //
    // What makes this mechanical is that a library announces itself:
    // anything offering shader text exports an accessor ending in
    // -shaders or -shader-functions, so the set that should be here is
    // derivable rather than remembered.
    // Checked against what the emitter ACTUALLY EMITTED, not against
    // its source text.  Searching the source for the accessor's name
    // passes a call that has been renamed or commented out, because the
    // name survives as an argument -- measured: disabling the call left
    // this test green.
    const libDir = join(root, 'lib', 'gfx');
    const emitted = new Set(emitAll().map(e => e.name.split('/')[0]));
    const missing = [];
    for (const f of readdirSync(libDir)) {
        if (!f.endsWith('.ss')) continue;
        const src = readFileSync(join(libDir, f), 'utf8');
        const accessors = [...src.matchAll(
            /^\s*\(define \(([a-z0-9-]*-shaders?(?:-functions)?)\)/mg)].map(m => m[1]);
        if (accessors.length === 0) continue;
        // At least one, not all of them: the accessors overlap.  A
        // library that offers both halves separately and the pair
        // together has three names for two shaders, and naming the
        // pair covers the halves.  It says "some of this library's
        // shader text is compiled", which is what catches a library
        // nobody added; it does not say every accessor is reached.
        if (!emitted.has(f.replace(/\.ss$/, '')))
            missing.push(`${f}: ${accessors.join(', ')}`);
    }
    assert.deepEqual(missing, [],
        'these accessors emit shader text that no compiler ever reads; ' +
        'add them to tools/shader-emit.ss:\n  ' + missing.join('\n  '));
});

if (!findChrome()) {
    console.log('NOT EXERCISED HERE (no Chrome beside this tree; the shaders this tree emits are not put in front of a real GLSL compiler here. rt/verify.mjs compiles a PAGE\'s shaders for real, but only the ones a page links, and it needs the same Chrome this check could not find)');
} else {
    console.log('EXERCISED HERE: the shaders this tree emits are compiled by a real GLSL compiler');
    const entries = emitAll();
    const control = entries.filter(e => e.name.startsWith('control/'));
    const real = entries.filter(e => !e.name.startsWith('control/'));
    assert.ok(real.length > 15, `only ${real.length} shaders were emitted; the accessors or the parse are wrong`);
    assert.strictEqual(control.length, 1, 'the deliberately invalid control did not come through');

    const results = await withBrowser(async page => {
        const out = [];
        for (const e of [...real, ...control]) {
            const vs = e.vs || PAIR[e.dialect].vs;
            const fs = e.fs || PAIR[e.dialect].fs;
            out.push([e, await checkShader(page, vs, fs)]);
        }
        return out;
    }, { timeoutMs: 120000 });


test('the shader a real compiler must refuse is refused', () => {
        const [, r] = results.find(([e]) => e.name.startsWith('control/'));
        assert.ok(!(r.vertex?.ok ?? true),
            'the known-bad shader compiled: what answered is a stub, and every other result here means nothing');
        assert.match(String(r.vertex?.log ?? ''), /\S/, 'it was refused without saying why');
    });

    // WHERE THIS GATE'S REACH ENDS, as a reading rather than as a
    // belief.  test/shader-functions-are-reached.mjs asks whether every
    // emitted function is called by a main, and the reason first given
    // for that -- repeated from a comment in tools/shader-emit.ss --
    // was that an uncalled function is dead code a driver discards
    // before reading its body.  This row is that claim, measured: with
    // nothing calling the function, four separate errors in its body
    // are all refused.  Bodies are checked whether or not they are
    // reached, so the other cell's value is the narrower one it now
    // states -- the SIGNATURE, which only a call site can disagree
    // with.
    //
    // It is here and not there because it needs this file's browser,
    // and it is a row rather than a note because a reason that stops
    // being true should turn something red.
    //
    // HOW FAR THE CLAIM REACHES.  An earlier version of this comment said
    // the row had been run under two GL implementations -- ANGLE's Metal
    // backend and SwiftShader -- which "share no compiler".  They share
    // the part that decides THIS row: both are ANGLE, and ANGLE parses and
    // validates a shader before either backend sees it.  Measured on
    // 2026-09-22: the same rejected shaders give byte-identical error logs
    // under both.  So a REFUSAL is one verdict, and asking the second
    // implementation for it again reads the same verdict twice -- which is
    // why this row, and the known-bad control, run under one.
    //
    // Acceptance is a different question, and a comment written the same
    // night said otherwise and was wrong in the same way: a shader the
    // front end accepts is then translated and linked by each backend on
    // its own, and those can fail on their own.  What was measured is a
    // rejected shader, not a set of accepted ones.  So the row at the end
    // of this file, which asks that every shader links, runs under both.
    test('an uncalled function body is compiled anyway', async () => {
        const vs = PAIR.es100.vs;
        const wrap = body => `precision mediump float;\n${body}\n`
            + 'void main(){ gl_FragColor = vec4(1.0); }';
        const bad = {
            'undefined function': 'float unused(float x){ return nosuchfn(x); }',
            'undeclared identifier': 'float unused(float x){ return x + undeclared_thing; }',
            'dimension mismatch': 'float unused(float x){ vec3 v = x; return v; }',
            'int from float literal': 'void unused(){ int n = 1.0; }',
        };
        const got = await withBrowser(async page => {
            const out = {};
            // The control comes first: an uncalled function with nothing
            // wrong must COMPILE, or every refusal below is about
            // something other than what is in the body.
            out.control = await checkShader(page, vs, wrap('float unused(float x){ return x*2.0; }'));
            for (const [k, src] of Object.entries(bad))
                out[k] = await checkShader(page, vs, wrap(src));
            return out;
        }, { timeoutMs: 120000 });

        assert.ok(got.control.fragment?.ok,
            'an uncalled function with nothing wrong in it was refused, so the '
            + 'refusals below say nothing about their bodies: '
            + String(got.control.fragment?.log || '').split('\n')[0]);
        // A refusal has to be a compiler's refusal.  checkShader answers
        // { context: null } when a page gets no GL context, and a probe
        // with no fragment result is not "refused" -- nothing looked at
        // it.  Counting only fragment.ok as acceptance made four probes
        // that never reached a compiler read as four refusals.
        const unread = Object.keys(bad)
            .filter(k => !got[k].fragment || !/\S/.test(String(got[k].fragment.log || '')));
        assert.deepStrictEqual(unread, [],
            'these probes came back with no compiler verdict at all (no context, '
            + 'or refused without a log), so they say nothing about whether the '
            + 'body was checked:\n  ' + unread.join('\n  '));
        const accepted = Object.keys(bad).filter(k => got[k].fragment.ok);
        assert.deepStrictEqual(accepted, [],
            'these errors were NOT caught in a function nobody calls, so an '
            + 'unreached function here really is unchecked and '
            + 'test/shader-functions-are-reached.mjs understates what it is '
            + 'for:\n  ' + accepted.join('\n  '));
    });

    const unlinked = rs => rs
        .filter(([e]) => !e.name.startsWith('control/'))
        .filter(([, r]) => !(r.vertex?.ok && r.fragment?.ok && r.linked))
        .map(([e, r]) => `${e.name} (${e.dialect}): ${(r.vertex?.log || r.fragment?.log || r.programLog || 'link failed').split('\n')[0]}`);

    test('every shader the libraries hand out compiles and links', () => {
        assert.deepStrictEqual(unlinked(results), []);
    });

    // THE SECOND BACKEND, for acceptance only (see HOW FAR THE CLAIM
    // REACHES above).  test/shader-functions-are-executed.mjs builds the
    // function sets on both backends before drawing them, but not the
    // whole shaders -- fx, ibl, post, sprite, scene, gltf, mesh,
    // particles -- so without this row nothing asks whether those link on
    // a backend other than the default one.
    const RENDERER = `(() => {
        const c = document.createElement('canvas');
        const gl = c.getContext('webgl2') || c.getContext('webgl');
        if (!gl) return null;
        const e = gl.getExtension('WEBGL_debug_renderer_info');
        return String(e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL)
                        : gl.getParameter(gl.RENDERER));
    })()`;
    const defaultRenderer = await withBrowser(page => page.evaluateInNewPage(RENDERER),
                                              { timeoutMs: 120000 });
    const second = await withBrowser(async page => {
        const renderer = await page.evaluateInNewPage(RENDERER);
        const out = [];
        for (const e of real) {
            const vs = e.vs || PAIR[e.dialect].vs;
            const fs = e.fs || PAIR[e.dialect].fs;
            out.push([e, await checkShader(page, vs, fs)]);
        }
        return { renderer, results: out };
    }, { timeoutMs: 120000, flags: ['--use-angle=swiftshader'] });

    // Without this, a flag that silently did nothing would make the row
    // below the default backend asked twice.
    test('the second launch is a different backend', () => {
        assert.ok(second.renderer, 'the second launch has no GL context');
        assert.match(second.renderer, /SwiftShader/);
        assert.notStrictEqual(second.renderer, defaultRenderer,
            'both launches report the same renderer');
    });

    test('[swiftshader] every shader the libraries hand out compiles and links', () => {
        assert.deepStrictEqual(unlinked(second.results), []);
    });
}
