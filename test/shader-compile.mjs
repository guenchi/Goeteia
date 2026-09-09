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
// test/shader-emit.ss, and not from a list kept here: a list here would
// be a second place to add a shader to, and the one that gets forgotten
// is always the second one.
//
// This stands down rather than failing when no browser is present.  The
// announcement goes through the same channel as every other stand-down
// in this suite, so it appears in the run's summary instead of passing
// in silence.
import { execFileSync } from 'node:child_process';
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
                     [join(root, 'test/shader-emit.ss'), wasm], { cwd: root });
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
