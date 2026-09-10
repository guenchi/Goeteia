// G08 (2026-09-06 review, still live 2026-09-09): a sprite tinted to
// zero alpha still puts its colour on the screen.
//
// RED ON PURPOSE, and rendered rather than reasoned about.  The sheet
// fragment shader is
//
//     gl_FragColor = texture2D(u_tex, v_uv) * v_tint
//
// a component-wise multiply.  The texture is PREMULTIPLIED and
// sheet-draw! selects premultiplied blending (ONE,
// ONE_MINUS_SRC_ALPHA), under which the right answer for a tint of
// alpha t is texel.rgb * tint.rgb * t.  The shader never multiplies rgb
// by tint.a, so at t = 0 the fragment still contributes its full colour
// through the ONE factor: a fade-out ends transparent and coloured.
//
// This is the first cell to use the frame probe, and it is the shape
// the probe was built for: draw the background, draw it again with the
// sprite over it, and require the two frames to be IDENTICAL.  An
// assertion about a pixel value would have to know what the right
// colour is; this one only has to know that drawing nothing visible
// changes nothing -- which is what "alpha zero" means and is true
// whatever the tint's colour is.
//
// The fragment shader is the library's own, taken from the emitter, and
// paired with a vertex shader written here.  That pairing is what
// test/shader-compile.mjs already does and for the same reason: the
// library offers one half because the other half is the caller's.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { findChrome, withBrowser, diffFrames } from '../tools/cdp.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

function sheetFragment() {
    const dir = mkdtempSync(join(tmpdir(), 'goeteia-tint-'));
    try {
        const wasm = join(dir, 'emit.wasm');
        execFileSync(join(root, 'bin/goeteiac'),
                     [join(root, 'tools/shader-emit.ss'), wasm], { cwd: root });
        const out = execFileSync('node', [join(root, 'rt/run.mjs'), wasm],
                                 { cwd: root, encoding: 'utf8', maxBuffer: 64 << 20 });
        const byName = new Map();
        let cur = null, part = null;
        for (const line of out.split('\n')) {
            const h = line.match(/^=== (\S+) (es\d+)$/);
            if (h) { cur = { name: h[1], vs: [], fs: [] }; byName.set(h[1], cur); part = null; continue; }
            if (line === '--- vertex ---') { part = 'vs'; continue; }
            if (line === '--- fragment ---') { part = 'fs'; continue; }
            if (cur && part) cur[part].push(line);
        }
        const sheet = byName.get('sprite/sheet');
        assert.ok(sheet && sheet.fs.join('').trim(),
                  'the emitter no longer prints a `sprite/sheet` fragment shader; '
                  + 'this cell can no longer find what it judges (saw: '
                  + [...byName.keys()].join(', ') + ')');
        return sheet.fs.join('\n');
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
}

const VS = 'attribute vec2 a_pos; varying vec2 v_uv; varying vec4 v_tint;'
         + ' uniform vec4 u_tint;'
         + ' void main(){ v_uv = a_pos * 0.5 + 0.5; v_tint = u_tint;'
         + ' gl_Position = vec4(a_pos, 0.0, 1.0); }';

// A 1x1 opaque white texture, already premultiplied (rgb == a).
const SETUP = (fsSrc, tintA) => `
  const mk = (kind, src) => { const s = gl.createShader(kind);
    gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS))
      throw new Error(gl.getShaderInfoLog(s));
    return s; };
  const p = gl.createProgram();
  gl.attachShader(p, mk(gl.VERTEX_SHADER, ${JSON.stringify(VS)}));
  gl.attachShader(p, mk(gl.FRAGMENT_SHADER, ${JSON.stringify(fsSrc)}));
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  gl.useProgram(p);
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE,
                new Uint8Array([255, 255, 255, 255]));
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.uniform1i(gl.getUniformLocation(p, 'u_tex'), 0);
  gl.uniform4f(gl.getUniformLocation(p, 'u_tint'), 1.0, 1.0, 1.0, ${tintA});
  const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(p, 'a_pos');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  gl.drawArrays(gl.TRIANGLES, 0, 3);`;

const BACKGROUND = 'gl.clearColor(0.0, 0.0, 0.6, 1.0); gl.clear(gl.COLOR_BUFFER_BIT);';

test('a sheet tinted to zero alpha leaves the frame alone', async () => {
    if (!findChrome()) {
        console.log('NOT EXERCISED HERE (no Chrome beside this tree; the sprite tint '
                    + 'is not put in front of a real GL, so a fade-out that leaves '
                    + 'colour behind would not be seen)');
        return;
    }
    const fsSrc = sheetFragment();
    await withBrowser(async page => {
        // the control first: a fully opaque tint MUST change the frame,
        // or this whole arrangement is drawing nothing and the real
        // assertion below would pass for the wrong reason
        const opaque = await diffFrames(page, BACKGROUND, BACKGROUND + SETUP(fsSrc, '1.0'));
        assert.ok(opaque.differing > 0,
                  'an opaque sprite drew nothing at all, so this cell is not '
                  + `set up to see anything (${JSON.stringify(opaque)})`);
        const faded = await diffFrames(page, BACKGROUND, BACKGROUND + SETUP(fsSrc, '0.0'));
        assert.equal(faded.differing, 0,
                     'a sprite tinted to alpha 0 changed '
                     + `${faded.differing} of ${faded.pixels} pixels `
                     + `(max delta ${faded.maxDelta}): the fragment shader does not `
                     + 'multiply rgb by the tint alpha, so a fade-out leaves colour');
    });
});
