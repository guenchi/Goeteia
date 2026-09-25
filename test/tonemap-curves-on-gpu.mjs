// The tone-mapping curves of (gfx post), measured where they run: on a
// GPU, at the precision the grade shader declares, under two GL
// implementations.
//
// Every expected byte below was computed in double precision from the
// published formulas BEFORE the functions were written, and is the
// function's output (linear, clamped, before the sRGB encode) times 255,
// rounded:
//   tonemap_aces       Narkowicz's fit, x(2.51x + 0.03) / (x(2.43x + 0.59) + 0.14),
//                      clamped -- the curve 'aces has always drawn, unchanged;
//   tonemap_aces_hill  Stephen Hill's fit of the ACES RRT + sRGB ODT: the
//                      sRGB-to-AP1 input matrix, a/b with
//                      a = v(v + 0.0245786) - 0.000090537 and
//                      b = v(0.983729v + 0.4329510) + 0.238081, the output
//                      matrix, clamped -- NOT scaled by 0.983729;
//   tonemap_reinhard   x(1 + x/9) / (1 + x), the extended curve with white 3.
//
// WHAT SEPARATES WHAT.
//   Hill from Narkowicz: grey 0.18 gives 27 against 68, and the two fits
//   differ at every grey below saturation.  On grey, Hill needs about
//   twice the exposure to give what Narkowicz gives: the ratio is 2.05,
//   2.01, 1.98, 2.00 and 2.12 at 0.05, 0.18, 0.5, 1.0 and 2.0, in double
//   precision (measured 2026-09-25 by the code session, recomputed here).
//   Hill as published from Hill scaled by 0.983729 (the normalisation an
//   upstream copy applies so that grey tends to white): grey 1.0 gives
//   158 against 155, three levels apart; the CONTROL row shows the two are
//   told apart on this GPU.
//   A saturated input: (4, 0, 0) gives red 255 while grey 4.0 gives 232 --
//   the output matrix carries a saturated channel past 1, where the clamp
//   takes it.
//   The mode selector: tonemap(x, 3.0) must be Hill, not Narkowicz.  The
//   grade shader used to select aces with step(1.5, mode), which a mode 3
//   also passes.
//
// THE CLAMPS ARE THE FUNCTION'S, not the framebuffer's.  A byte read back
// is clamped to [0,1] by the target whatever the shader wrote, so a row
// that reads f(x) directly cannot see whether f clamps.  The rows marked
// "scaled" read f(x) times 0.4 or 0.8: a clamped 1.0 reads 102 or 204, an
// unclamped 1.2246 or 1.0196 reads 125 or 208.  Hill's input clamp is
// likewise read on a vector with one negative channel: clamping each
// channel before the input matrix gives (43, 101, 237), clamping after it
// gives (0, 92, 238).
//
// THE GRADE SHADER USES THESE FUNCTIONS.  Measuring the functions says
// nothing about the program that grades a frame unless that program calls
// them: its main must select with tonemap(..., u_mode), and every function
// it defines must be the same text the tonemap/functions entry emits, so
// there is one copy and not two that can drift.
//
// NOT PINNED HERE, on purpose: what 'aces and 'reinhard do with a NEGATIVE
// input (Narkowicz gives white for -1, reinhard divides by zero).  That is
// recorded as a defect, and a row here would turn it into a promise.
// Hill's output for a negative grey is about -0.0004 before its final
// clamp; no byte can tell that from 0, so that clamp is read only on the
// saturated side.
//
// PRECISION.  The grade shader declares mediump, and a GPU may carry that
// in 16 bits.  Every row allows one level either way; every row that
// separates two answers separates them by at least three.
import { test } from 'node:test';
import assert from 'node:assert';
import { findChrome, withBrowser, checkShader } from '../tools/cdp.mjs';
import { emitAll } from '../tools/shader-emit.mjs';
import { readFileSync } from 'node:fs';

const emitted = emitAll();
const entry = emitted.find(e => e.name === 'tonemap/functions');
const grade = emitted.find(e => e.name === 'post/grade');
const root = new URL('..', import.meta.url).pathname;

function functionsText() {
    const fs = entry.fs;
    const at = fs.search(/void\s+main\s*\(/);
    return fs.slice(0, at).replace(/precision\s+highp\s+float\s*;/, 'precision mediump float;');
}

const VS = 'attribute vec2 a_pos; void main(){ gl_Position = vec4(a_pos, 0.0, 1.0); }';
const shader = expr => `${functionsText()}
void main(){ gl_FragColor = vec4(${expr}, 1.0); }`;
const v3 = (r, g, b) => `vec3(${[r, g, b].map(x => x.toFixed(6)).join(', ')})`;
const grey = x => v3(x, x, x);

// [name, expression, expected bytes r g b]
const CASES = [
    ['hill grey 0.02', `tonemap_aces_hill(${grey(0.02)})`, [1, 1, 1]],
    ['hill grey 0.18', `tonemap_aces_hill(${grey(0.18)})`, [27, 27, 27]],
    ['hill grey 0.5', `tonemap_aces_hill(${grey(0.5)})`, [95, 95, 95]],
    ['hill grey 1.0 (normalised would be 155)', `tonemap_aces_hill(${grey(1.0)})`, [158, 158, 158]],
    ['hill grey 4.0', `tonemap_aces_hill(${grey(4.0)})`, [232, 232, 232]],
    ['hill grey 16.0', `tonemap_aces_hill(${grey(16.0)})`, [252, 252, 252]],
    ['hill saturated red past 1, clamped', `tonemap_aces_hill(${v3(4, 0, 0)})`, [255, 39, 10]],
    ['hill saturated blue past 1, clamped', `tonemap_aces_hill(${v3(0, 0, 8)})`, [91, 8, 255]],
    ['hill mixed channels', `tonemap_aces_hill(${v3(0.18, 0.5, 4)})`, [76, 101, 237]],
    ['hill negative input is black', `tonemap_aces_hill(${grey(-1)})`, [0, 0, 0]],
    ['hill clamps each channel before the input matrix', `tonemap_aces_hill(${v3(-1, 0.5, 4)})`, [43, 101, 237]],
    ['hill scaled 0.4: its own clamp holds red at 1', `tonemap_aces_hill(${v3(4, 0, 0)}) * 0.4`, [102, 16, 4]],
    ['hill scaled 0.8: its own clamp holds blue at 1', `tonemap_aces_hill(${v3(0, 0, 8)}) * 0.8`, [73, 7, 204]],
    ['narkowicz grey 0.02, unchanged', `tonemap_aces(${grey(0.02)})`, [3, 3, 3]],
    ['narkowicz grey 0.18, unchanged', `tonemap_aces(${grey(0.18)})`, [68, 68, 68]],
    ['narkowicz grey 0.5, unchanged', `tonemap_aces(${grey(0.5)})`, [157, 157, 157]],
    ['narkowicz grey 1.0, unchanged', `tonemap_aces(${grey(1.0)})`, [205, 205, 205]],
    ['narkowicz grey 4.0, unchanged', `tonemap_aces(${grey(4.0)})`, [248, 248, 248]],
    ['narkowicz mixed channels, unchanged', `tonemap_aces(${v3(0.18, 0.5, 4)})`, [68, 157, 248]],
    ['reinhard grey 0.18', `tonemap_reinhard(${grey(0.18)})`, [40, 40, 40]],
    ['reinhard grey 0.5', `tonemap_reinhard(${grey(0.5)})`, [90, 90, 90]],
    ['reinhard grey 1.0', `tonemap_reinhard(${grey(1.0)})`, [142, 142, 142]],
    ['select 0 is the input', `tonemap(${grey(0.4)}, 0.0)`, [102, 102, 102]],
    ['select 1 is reinhard', `tonemap(${grey(0.5)}, 1.0)`, [90, 90, 90]],
    ['select 2 is narkowicz', `tonemap(${grey(0.5)}, 2.0)`, [157, 157, 157]],
    ['select 3 is hill, not narkowicz', `tonemap(${grey(0.5)}, 3.0)`, [95, 95, 95]],
    ['select 1 keeps channels apart', `tonemap(${v3(0.18, 0.5, 4)}, 1.0)`, [40, 90, 255]],
    ['select 2 keeps channels apart', `tonemap(${v3(0.18, 0.5, 4)}, 2.0)`, [68, 157, 248]],
    ['select 3 keeps channels apart', `tonemap(${v3(0.18, 0.5, 4)}, 3.0)`, [76, 101, 237]],
    ['select 0 scaled 0.4: the input passes unclamped', `tonemap(${v3(2, 0.5, 0.1)}, 0.0) * 0.4`, [204, 51, 10]],
];
// CONTROL: the normalised variant, built here, must read three levels
// from the published one on this GPU, or the row that tells them apart
// is not telling them apart.
const CONTROL = ['CONTROL hill scaled by 0.983729 at grey 1.0', `clamp(tonemap_aces_hill(${grey(1.0)}) * 0.983729, 0.0, 1.0)`, [155, 155, 155]];

test('the emitter hands out the tone-mapping functions', () => {
    assert.ok(entry, 'tools/shader-emit.ss emits no tonemap/functions entry, so nothing here '
        + 'can read the functions a GPU would compile');
    for (const f of ['tonemap_aces_hill', 'tonemap_aces', 'tonemap_reinhard', 'tonemap'])
        assert.match(entry.fs, new RegExp(`\\b${f}\\s*\\(`), `no ${f} in the emitted functions`);
});

// The functions defined in a GLSL text, name -> full definition text,
// found by matching braces from each "type name(params) {".  The emitter
// writes a shader on ONE line, so nothing here may anchor on a line
// start.  A local declaration never matches: "vec3 x = ..." has no
// parameter list, and a call's arguments nest parentheses, which the
// parameter pattern does not admit.
function definitions(src) {
    const out = {};
    const re = /\b(?:vec[234]|float|void|int|bool|mat[234])\s+([A-Za-z_]\w*)\s*\([^()]*\)\s*\{/g;
    for (const m of src.matchAll(re)) {
        let depth = 0, i = m.index + m[0].length - 1;
        for (; i < src.length; i++) {
            if (src[i] === '{') depth++;
            else if (src[i] === '}' && --depth === 0) break;
        }
        out[m[1]] = src.slice(m.index, i + 1);
    }
    return out;
}

// CONTROL for the reading below: in the grade shader as it stands, the
// parser finds the functions it certainly has.  Without this, a parser
// that found nothing would make "main does not call tonemap" true for
// the wrong reason.
test('CONTROL the definition reader finds the grade shader\'s own functions', () => {
    assert.ok(grade, 'no post/grade entry is emitted');
    const found = Object.keys(definitions(grade.fs));
    for (const f of ['decode_srgb', 'encode_srgb', 'main'])
        assert.ok(found.includes(f), `the reader did not find ${f}; it found ${found.join(', ')}`);
});

test('the grade shader selects with tonemap(..., u_mode) and keeps no inline curve', () => {
    assert.ok(grade, 'no post/grade entry is emitted');
    const main = definitions(grade.fs).main || '';
    assert.match(main, /\btonemap\s*\([^;]*\bu_mode\b/, 'the grade main does not call tonemap(..., u_mode)');
    assert.doesNotMatch(main, /2\.43|2\.51|0\.0245786/, 'the grade main still carries a curve of its own');
});

test('the grade shader defines each tone-mapping function as the entry emits it, once', () => {
    assert.ok(entry && grade);
    const mine = definitions(entry.fs);
    const theirs = definitions(grade.fs);
    const differ = ['tonemap_reinhard', 'tonemap_aces', 'tonemap_aces_hill', 'tonemap']
        .filter(f => !mine[f] || mine[f] !== theirs[f]);
    assert.deepStrictEqual(differ, [], 'these differ between tonemap/functions and post/grade: ' + differ.join(', '));
});

test('the documentation names both fits and the new mode', () => {
    const api = readFileSync(root + 'docs/api.md', 'utf8');
    const graphics = readFileSync(root + 'docs/graphics.md', 'utf8');
    assert.match(api, /tonemap-shader-functions/, 'docs/api.md has no entry for tonemap-shader-functions');
    assert.match(api, /'aces-hill/, "docs/api.md does not name 'aces-hill");
    assert.match(graphics, /Narkowicz/, 'docs/graphics.md does not say which fit \'aces is');
    assert.match(graphics, /Hill/, 'docs/graphics.md does not say which fit \'aces-hill is');
});

if (!findChrome()) {
    console.log('NOT EXERCISED HERE (no Chrome beside this tree; the tone-mapping curves '
        + 'are only measured on a GPU, at the precision the grade shader declares)');
} else if (entry) {
    console.log('EXERCISED HERE: the tone-mapping curves run on two GL implementations');
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
                return r.fragment?.ok && r.linked && r.pixel ? r.pixel.slice(0, 3)
                     : `no pixel (${(r.fragment?.log || r.programLog || 'no context').split('\n')[0]})`;
            };
            const out = { ...impl, renderer, cases: [] };
            for (const [name, expr, want] of [...CASES, CONTROL])
                out.cases.push({ name, want, got: await read(shader(expr)) });
            return out;
        }, { timeoutMs: 120000, flags: impl.flags }));
    }

    test('the two launches are two different GL implementations', () => {
        for (const r of runs) assert.ok(r.renderer, `the ${r.name} launch has no GL context`);
        assert.notStrictEqual(runs[0].renderer, runs[1].renderer);
    });

    const near = (got, want) => Array.isArray(got) && got.every((g, i) => Math.abs(g - want[i]) <= 1);

    for (const run of runs) {
        test(`[${run.name}] the curves give the published values`, () => {
            const bad = run.cases.filter(k => !k.name.startsWith('CONTROL') && !near(k.got, k.want))
                .map(k => `${k.name}: got ${k.got}, want ${k.want}`);
            assert.deepStrictEqual(bad, [], bad.join('\n'));
        });
        test(`[${run.name}] CONTROL the normalised variant reads apart from the published fit here`, () => {
            const k = run.cases.find(c => c.name.startsWith('CONTROL'));
            assert.ok(near(k.got, k.want), `${k.name}: got ${k.got}, want ${k.want}`);
        });
    }
}
