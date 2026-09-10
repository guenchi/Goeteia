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
import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import assert from 'node:assert';
import { findChrome, withBrowser, checkShader, NoBrowser } from '../tools/cdp.mjs';

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

function emitAll() {
    const dir = mkdtempSync(join(tmpdir(), 'goeteia-shaders-'));
    try {
        const wasm = join(dir, 'emit.wasm');
        execFileSync(join(root, 'bin/goeteiac'),
                     [join(root, 'tools/shader-emit.ss'), wasm], { cwd: root });
        const out = execFileSync('node', [join(root, 'rt/run.mjs'), wasm],
                                 { cwd: root, encoding: 'utf8', maxBuffer: 64 << 20 });
        const entries = [];
        let cur = null, part = null;
        for (const line of out.split('\n')) {
            const h = line.match(/^=== (\S+) (es\d+)$/);
            if (h) { cur = { name: h[1], dialect: h[2], vs: [], fs: [] }; entries.push(cur); part = null; continue; }
            if (line === '--- vertex ---') { part = 'vs'; continue; }
            if (line === '--- fragment ---') { part = 'fs'; continue; }
            if (cur && part) cur[part].push(line);
        }
        return entries.map(e => ({
            name: e.name, dialect: e.dialect,
            vs: e.vs.join('\n').trim(), fs: e.fs.join('\n').trim(),
        }));
    } finally { rmSync(dir, { recursive: true, force: true }); }
}

if (!findChrome()) {
    console.log('NOT EXERCISED HERE (no Chrome beside this tree; the shaders this tree emits are not put in front of a real GLSL compiler, and the recording GL in rt/verify.mjs accepts every one of them)');
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
    // ⚠️ Checked against what the emitter ACTUALLY EMITTED, not against
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
        // pair covers the halves.  ⇒ This says "some of this library's
        // shader text is compiled", which is what catches a library
        // nobody added; it does not say every accessor is reached.
        if (!emitted.has(f.replace(/\.ss$/, '')))
            missing.push(`${f}: ${accessors.join(', ')}`);
    }
    assert.deepEqual(missing, [],
        'these accessors emit shader text that no compiler ever reads; ' +
        'add them to tools/shader-emit.ss:\n  ' + missing.join('\n  '));
});

test('the shader a real compiler must refuse is refused', () => {
        const [, r] = results.find(([e]) => e.name.startsWith('control/'));
        assert.ok(!(r.vertex?.ok ?? true),
            'the known-bad shader compiled: what answered is a stub, and every other result here means nothing');
        assert.match(String(r.vertex?.log ?? ''), /\S/, 'it was refused without saying why');
    });

    test('every shader the libraries hand out compiles and links', () => {
        const bad = results
            .filter(([e]) => !e.name.startsWith('control/'))
            .filter(([, r]) => !(r.vertex?.ok && r.fragment?.ok && r.linked))
            .map(([e, r]) => `${e.name} (${e.dialect}): ${(r.vertex?.log || r.fragment?.log || r.programLog || 'link failed').split('\n')[0]}`);
        assert.deepStrictEqual(bad, []);
    });
}
