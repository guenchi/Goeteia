// Reachable is not the same as executed, and this cell is the
// difference.
//
// test/shader-functions-are-reached.mjs answers "does main lead here",
// by reading text.  It said yes for water_shore_foam while every pixel
// took the branch that returns before the body: the call was reached and
// the body was dead, because the arguments in tools/shader-emit.ss put
// depth past the band.  Three such cases turned up in one batch -- that
// call, the same call in a second harness, and tangent_frame, whose
// bump argument decoded to exactly the z axis, which safe_unit then
// normalised away.  None of them could be seen without drawing.
//
// So each function's LAST return -- the one after any early exit -- is
// perturbed in turn, the emitted program is drawn, and the frame has to
// change.  A function whose body never runs draws the same frame and is
// named.
//
// THE PERTURBATION HAS A RANGE, and each limit below was found by this
// probe reading a live function as DEAD.  They are here so the next
// person does not simplify the perturbation back to what failed:
//
//   Adding 17.0 was clamped to 1.0 by every channel, so any term already
//   at or above 1 lost the change: eleven functions read DEAD.  A scale
//   and shift stays inside the range and moves 0 as well as 1.
//
//   A uniform scale of a mat3 whose result reaches the frame through
//   safe_unit is exactly the change normalising removes.  mat3 is scaled
//   ANISOTROPICALLY.
//
//   The main sums many terms into one channel, and a sum well above 1
//   saturates, so a change to one term is clamped away.  Every channel is
//   read through fract() -- on BOTH sides, so the comparison still
//   isolates the perturbed function.  A reading cannot report a
//   difference its representation cannot hold.
//
//   The output assignment is vec4(a, b, ...) where the arguments contain
//   commas inside nested calls, so it is split by a scanner that counts
//   parentheses.  A regular expression cut it in the wrong place and
//   produced fract() around half an argument list.
//
// Those four limits were measured in front of one GL implementation.
// This cell runs under two, so a range limit that belongs to one driver
// shows up as a disagreement instead of as a belief.  Be exact about
// what the second one adds: both are ANGLE, and the same ANGLE front end
// parses and validates the shader -- the same rejected shader gives
// byte-identical logs under both, measured.  What differs is everything
// after that, code generation and rasterisation, and that is precisely
// what drawing a frame exercises.  (test/shader-compile.mjs asks the
// second backend only whether accepted shaders link, for the same
// reason: a refusal is the front end's and is one verdict.)
//
// The shaders come from tools/shader-emit.mjs and are emitted afresh on
// every run.  The instrument this was promoted from read a saved
// emit.txt, which is a copy that goes stale the moment the source moves
// and still produces confident readings about the old source.
import { test } from 'node:test';
import assert from 'node:assert';
import { findChrome, withBrowser, diffFrames } from '../tools/cdp.mjs';
import { emitAll } from '../tools/shader-emit.mjs';

const BUMP = {
    float: '* 0.37 + 0.013',
    vec2: '* 0.37 + vec2(0.013)',
    vec3: '* 0.37 + vec3(0.013)',
    vec4: '* 0.37 + vec4(0.013)',
    mat3: '* mat3(1.3, 0.0, 0.0, 0.0, 0.7, 0.0, 0.0, 0.0, 1.1)',
};
const TYPE = '(?:float|vec2|vec3|vec4|mat2|mat3|mat4|bool|int)';

function definitions(src) {
    return [...src.matchAll(new RegExp('\\b(' + TYPE.slice(3, -1)
                                       + ')\\s+([A-Za-z_]\\w*)\\s*\\(', 'g'))]
        .map(m => ({ type: m[1], name: m[2], at: m.index }))
        .filter(d => d.name !== 'main');
}

function bodyOf(src, d) {
    const i = src.indexOf('{', d.at);
    let depth = 1, j = i + 1;
    for (; j < src.length && depth; j++) {
        if (src[j] === '{') depth++;
        else if (src[j] === '}') depth--;
    }
    return [i + 1, j - 1];
}

// Wrap every top-level argument of the output vec4 in fract().
function readout(src) {
    const m = src.match(/\b(goe_FragColor|gl_FragColor)\s*=\s*vec4\(/);
    if (!m) throw new Error('output assignment not found');
    const open = m.index + m[0].length;
    const cuts = [open];
    let depth = 1, j = open;
    for (; j < src.length && depth; j++) {
        const c = src[j];
        if (c === '(') depth++;
        else if (c === ')') depth--;
        else if (c === ',' && depth === 1) cuts.push(j + 1);
    }
    const close = j - 1;
    const args = cuts.map((c, k) =>
        src.slice(c, k + 1 < cuts.length ? cuts[k + 1] - 1 : close).trim());
    return src.slice(0, open) + args.map(a => `fract(${a})`).join(', ')
         + src.slice(close);
}

function perturbed(src, d) {
    const [s, e] = bodyOf(src, d);
    const body = src.slice(s, e);
    const last = body.lastIndexOf('return ');
    if (last < 0) return null;
    const semi = body.indexOf(';', last);
    const expr = body.slice(last + 7, semi);
    return src.slice(0, s) + body.slice(0, last)
         + `return (${expr}) ${BUMP[d.type]};` + body.slice(semi + 1) + src.slice(e);
}

const draw = (vs, fs) => `
const mk=(t,s)=>{const sh=gl.createShader(t);gl.shaderSource(sh,s);gl.compileShader(sh);
 if(!gl.getShaderParameter(sh,gl.COMPILE_STATUS))throw new Error(gl.getShaderInfoLog(sh));return sh;};
const p=gl.createProgram();
gl.attachShader(p,mk(gl.VERTEX_SHADER,${JSON.stringify(vs)}));
gl.attachShader(p,mk(gl.FRAGMENT_SHADER,${JSON.stringify(fs)}));
gl.linkProgram(p);
if(!gl.getProgramParameter(p,gl.LINK_STATUS))throw new Error(gl.getProgramInfoLog(p));
gl.useProgram(p);
const tex=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,tex);
gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,2,2,0,gl.RGBA,gl.UNSIGNED_BYTE,
 new Uint8Array([31,97,203,255,211,43,157,255,73,181,29,255,149,61,229,255]));
gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.NEAREST);
gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.NEAREST);
const u=gl.getUniformLocation(p,'u_surface_tex'); if(u) gl.uniform1i(u,0);
const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);
gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),gl.STATIC_DRAW);
const l=gl.getAttribLocation(p,'a_pos');gl.enableVertexAttribArray(l);
gl.vertexAttribPointer(l,2,gl.FLOAT,false,0,0);
gl.drawArrays(gl.TRIANGLES,0,3);
const e=gl.getError(); if(e) throw new Error('gl error '+e);
`;

const sets = emitAll().filter(e => e.name.endsWith('/functions'));

if (!findChrome()) {
    console.log('NOT EXERCISED HERE (no Chrome beside this tree; nothing renders, so '
        + 'whether each function AFFECTS the frame cannot be asked here at all -- '
        + 'a function that is reached and dead reads the same as one that works. '
        + 'To exercise it: npx puppeteer browsers install chrome, or put a Chrome '
        + 'or Chromium binary where findChrome looks)');
} else {
    console.log('EXERCISED HERE: each function body is perturbed and the emitted program is redrawn');

    const IMPLS = [
        { name: 'default', flags: [] },
        { name: 'swiftshader', flags: ['--use-angle=swiftshader'] },
    ];

    const runs = [];
    for (const impl of IMPLS) {
        runs.push(await withBrowser(async page => {
            const renderer = await page.evaluateInNewPage(`(() => {
                const c = document.createElement('canvas');
                const gl = c.getContext('webgl2') || c.getContext('webgl');
                if (!gl) return null;
                const e = gl.getExtension('WEBGL_debug_renderer_info');
                return String(e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL)
                                : gl.getParameter(gl.RENDERER));
            })()`);
            const out = { ...impl, renderer, rows: [], same: [], control: [] };
            for (const set of sets) {
                const base = readout(set.fs);
                // Drawn against itself first: if the same source draws two
                // different frames, a difference below says nothing about
                // the perturbation.
                out.same.push({ set: set.name,
                    r: await diffFrames(page, draw(set.vs, base), draw(set.vs, base)) });
                for (const d of definitions(set.fs)) {
                    if (!BUMP[d.type]) { out.rows.push({ set: set.name, d, skip: 'no perturbation for type ' + d.type }); continue; }
                    const m = perturbed(set.fs, d);
                    if (!m) { out.rows.push({ set: set.name, d, skip: 'no return statement' }); continue; }
                    out.rows.push({ set: set.name, d,
                        r: await diffFrames(page, draw(set.vs, base), draw(set.vs, readout(m))) });
                }
                // CONTROL: a function nothing calls must read DEAD, or a
                // LIVE below could mean the probe cannot say DEAD at all.
                const withDead = set.fs.replace(/\bvoid\s+main\s*\(/,
                    'float zz_uncalled(float x) { return x * 2.0; }\nvoid main(');
                const dz = definitions(withDead).find(d => d.name === 'zz_uncalled');
                out.control.push({ set: set.name,
                    r: await diffFrames(page, draw(set.vs, readout(withDead)),
                                              draw(set.vs, readout(perturbed(withDead, dz)))) });
            }
            return out;
        }, { timeoutMs: 180000, flags: impl.flags }));
    }

    test('the two launches are two different GL implementations', () => {
        for (const r of runs)
            assert.ok(r.renderer, `the ${r.name} launch has no GL context`);
        assert.notStrictEqual(runs[0].renderer, runs[1].renderer,
            'both launches report the same renderer, so the second set of rows '
            + 'asks the first implementation again');
        console.log('implementations: ' + runs.map(r => `${r.name} = ${r.renderer}`).join('; '));
    });

    test('there are function sets and functions to perturb', () => {
        assert.ok(sets.length >= 3, `only ${sets.length} function sets were emitted`);
        const n = runs[0].rows.length;
        assert.ok(n >= 20, `only ${n} functions were found to perturb; the parse `
            + 'is wrong and every row below is green on too few');
    });

    for (const run of runs) {
        test(`[${run.name}] the same source draws the same frame twice`, () => {
            const noisy = run.same.filter(x => x.r.differing !== 0)
                .map(x => `${x.set}: differing=${x.r.differing} ${x.r.error || ''}`);
            assert.deepStrictEqual(noisy, [],
                'drawing a program against itself differed, so a difference from a '
                + 'perturbation below would not be evidence of anything');
        });

        test(`[${run.name}] CONTROL an uncalled function reads DEAD`, () => {
            const live = run.control.filter(x => !(x.r.differing === 0))
                .map(x => `${x.set}: differing=${x.r.differing} ${x.r.error || ''}`);
            assert.deepStrictEqual(live, [],
                'perturbing a function nothing calls changed the frame, or failed to '
                + 'draw; this probe cannot say DEAD and its LIVE readings mean nothing');
        });

        test(`[${run.name}] every function body changes the frame when perturbed`, () => {
            const dead = run.rows.filter(x => x.skip || !(typeof x.r.differing === 'number' && x.r.differing > 0))
                .map(x => `${x.d.name} (${x.set}): ${x.skip || (x.r.error ? 'draw failed: ' + x.r.error : 'differing=' + x.r.differing)}`);
            assert.deepStrictEqual(dead, [],
                'these functions are reached but perturbing their last return does not '
                + 'change the frame -- the arguments in tools/shader-emit.ss send every '
                + 'pixel past that return, or a range limit above swallowed the change:\n  '
                + dead.join('\n  '));
        });
    }
}
