// The sRGB transfer functions, measured where they run: on a GPU, at the
// precision the library's shaders declare, under two GL implementations.
//
// Every expected byte below was computed in double precision from the
// sRGB definition BEFORE the functions were written -- linear below
// 0.04045 (decoding) or 0.0031308 (encoding), a 2.4 power above -- so
// the rows are a specification and not a transcript of what the code
// happened to answer.
//
// WHICH ROWS TELL THE OLD FORMULA FROM THE NEW.  A colour decoded and
// encoded untouched comes back to the same byte under both pow(x, 2.2)
// and the exact functions -- all 256 values, checked in double -- so the
// round-trip rows prove only that an unlit colour is left alone.  What
// separates the two is lighting in between and the dark end:
//
//   decode(47/255) x 0.1, encoded      exact 9    old 17
//   decode(10/255) x 100               exact 77   old 21
//   decode(128/255) x decode(128/255)  exact 61   old 64
//
// The last one is also the shape that lived at lib/gfx/mesh.ss:916: a
// texture and a colour multiplied while still encoded and then decoded
// together.  Under a pure power that product is exact by accident; under
// the real transfer function it is not.  Decoding the product instead of
// each factor gives 64, the same as the old formula.
//
// PRECISION.  The mesh shaders declare mediump, and a GPU may carry that
// in 16 bits.  The rows allow one level either way, and every
// discriminating row above is at least three levels from its old answer,
// so the tolerance cannot blur the question.
import { test } from 'node:test';
import assert from 'node:assert';
import { findChrome, withBrowser, checkShader } from '../tools/cdp.mjs';
import { emitAll } from '../tools/shader-emit.mjs';

const entry = emitAll().find(e => e.name === 'srgb/functions');

// The functions as emitted, without the emitter's own main, at the
// precision the library's shaders declare.
function functionsText() {
    const fs = entry.fs;
    const at = fs.search(/void\s+main\s*\(/);
    return fs.slice(0, at).replace(/precision\s+highp\s+float\s*;/, 'precision mediump float;');
}

const VS = 'attribute vec2 a_pos; void main(){ gl_Position = vec4(a_pos, 0.0, 1.0); }';
const shader = expr => `${functionsText()}
void main(){ float v = ${expr}; gl_FragColor = vec4(v, v, v, 1.0); }`;
const oldShader = expr => `precision mediump float;
vec3 decode_srgb(vec3 c){ return pow(c, vec3(2.2)); }
vec3 encode_srgb(vec3 c){ return pow(c, vec3(1.0 / 2.2)); }
void main(){ float v = ${expr}; gl_FragColor = vec4(v, v, v, 1.0); }`;

const c = x => `vec3(${(x / 255).toFixed(9)})`;
const CASES = [
    ['a dark colour lit at a tenth', `encode_srgb(decode_srgb(${c(47)}) * 0.1).r`, 9, 17],
    ['a dark colour decoded, scaled by 100', `(decode_srgb(${c(10)}) * 100.0).r`, 77, 21],
    ['two factors decoded separately, then multiplied', `encode_srgb(decode_srgb(${c(128)}) * decode_srgb(${c(128)})).r`, 61, 64],
    ['a light colour decoded', `decode_srgb(${c(200)}).r`, 147, 149],
];
const ROUND = [0, 10, 47, 128, 200, 255];

test('the emitter hands out the sRGB functions', () => {
    assert.ok(entry, 'tools/shader-emit.ss emits no srgb/functions entry, so nothing here '
        + 'can read the functions a GPU would compile');
    assert.match(entry.fs, /decode_srgb/);
    assert.match(entry.fs, /encode_srgb/);
});

if (!findChrome()) {
    console.log('NOT EXERCISED HERE (no Chrome beside this tree; the transfer functions '
        + 'are only measured on a GPU, at the precision the shaders declare)');
} else if (entry) {
    console.log('EXERCISED HERE: the sRGB transfer functions run on two GL implementations');
    const IMPLS = [
        { name: 'default', flags: [] },
        { name: 'swiftshader', flags: ['--use-angle=swiftshader'] },
    ];
    const runs = [];
    for (const impl of IMPLS) {
        runs.push(await withBrowser(async page => {
            const renderer = await page.evaluateInNewPage(`(() => {
                const cv = document.createElement('canvas');
                const gl = cv.getContext('webgl2') || cv.getContext('webgl');
                if (!gl) return null;
                const e = gl.getExtension('WEBGL_debug_renderer_info');
                return String(e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER));
            })()`);
            const read = async src => {
                const r = await checkShader(page, VS, src);
                return r.fragment?.ok && r.linked && r.pixel ? r.pixel[0]
                     : `no pixel (${(r.fragment?.log || r.programLog || 'no context').split('\n')[0]})`;
            };
            const out = { ...impl, renderer, cases: [], old: [], round: [] };
            for (const [name, expr, want, old] of CASES)
                out.cases.push({ name, want, old, got: await read(shader(expr)), gotOld: await read(oldShader(expr)) });
            for (const x of ROUND)
                out.round.push({ x, got: await read(shader(`encode_srgb(decode_srgb(${c(x)})).r`)) });
            return out;
        }, { timeoutMs: 120000, flags: impl.flags }));
    }

    test('the two launches are two different GL implementations', () => {
        for (const r of runs) assert.ok(r.renderer, `the ${r.name} launch has no GL context`);
        assert.notStrictEqual(runs[0].renderer, runs[1].renderer);
    });

    const near = (got, want) => typeof got === 'number' && Math.abs(got - want) <= 1;

    for (const run of runs) {
        test(`[${run.name}] the transfer functions give the sRGB values`, () => {
            const bad = run.cases.filter(k => !near(k.got, k.want))
                .map(k => `${k.name}: got ${k.got}, want ${k.want} (the old formula gives ${k.old})`);
            assert.deepStrictEqual(bad, [], bad.join('\n'));
        });

        // CONTROL.  The same expressions through the old pow pair must give
        // the OLD bytes on this GPU.  If they did not, the rows above would
        // not be separating the two formulas on this implementation, and a
        // pass there would say nothing about which one is in the library.
        test(`[${run.name}] CONTROL the old formula still gives the old values here`, () => {
            const bad = run.cases.filter(k => k.name !== 'a light colour decoded' && !near(k.gotOld, k.old))
                .map(k => `${k.name}: the old formula gave ${k.gotOld}, want ${k.old}`);
            assert.deepStrictEqual(bad, [], bad.join('\n'));
        });

        test(`[${run.name}] an untouched colour comes back to the same byte`, () => {
            const bad = run.round.filter(k => !near(k.got, k.x)).map(k => `${k.x} came back as ${k.got}`);
            assert.deepStrictEqual(bad, [], bad.join('\n'));
        });
    }
}
