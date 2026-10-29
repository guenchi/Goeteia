// A multisampled MRT target, resolved, read back on a real GPU against a
// same-context reference.
//
// fx-target-mrt-msaa! renders into multisampled colour and depth
// attachments; fx-resolve! blits each colour attachment and the depth into
// single-sampled textures, the depth one sampleable.  A mock GL can show
// which calls are made, not whether WebGL accepts them, so this cell runs
// the library's own command stream and replayer in Chrome, under the two
// GL implementations test/shader-compile.mjs uses.
//
// THE PROGRAM (compiled to JS by the Chez-hosted compiler; the replayer is
// JS on every target) draws one triangle -- the lower-left half of the
// target, its long edge across the diagonal -- into a 2-attachment target:
// output 0 one colour, output 1 another, at a known depth.  It resolves,
// then draws each resolved texture (colour 0, colour 1, depth as grey)
// with a full-screen pass into an RGBA8 observation target and reads the
// bytes back with cmd-read-pixels!.  It does this twice, with the colours
// and the depth changed, so a stale resolve shows.
//
// THE REFERENCE runs after it in the same page, on the same WebGL2
// context, in raw WebGL2: the same triangle, colours, depth, sample count
// and formats, its own per-attachment readBuffer/drawBuffers and its own
// depth blit, observed by an equivalent full-screen pass.  Identical inputs
// on one implementation resolve the same way, so the library's bytes must
// EQUAL the reference's -- a resolve of the wrong attachment, a skipped
// depth, or a target that ran single-sampled differs at the edge.  No
// particular antialiasing result is asserted.
//
// Also: interior pixels against their analytic values (RGBA8, one level
// of tolerance); the sample count the target reports is above 1, AND every
// multisampled renderbuffer the library allocated reports that count from
// the driver (getRenderbufferParameter RENDERBUFFER_SAMPLES, the
// renderbuffers recorded as the library allocates them); gl.getError() is
// NO_ERROR at the end.  The single-sampled fx-target-mrt! is drawn into
// too, and its depth texture observed: its depth is sampleable now.
//
// A context that cannot multisample RGBA16F makes the program refuse at
// construction, with fx-target-mrt-msaa! as the condition's who; the row
// is then SKIPPED, visibly, with the refusal as the reason -- not passed.
// Any other error fails.  Without Chrome the rows are skipped the same way.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { findChrome, withBrowser } from '../tools/cdp.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const W = 32, H = 32;
const CYCLES = [
    { c0: [0.8, 0.2, 0.1], c1: [0.1, 0.3, 0.9], z: 0.25 },
    { c0: [0.1, 0.9, 0.4], c1: [0.7, 0.6, 0.0], z: -0.5 },
];
const fl = x => x.toFixed(4);

// the goeteia program: every cycle prints "C<k> <A hex> <B hex> <D hex>"
const program = `(import (rnrs) (web js) (gfx gl) (gfx fx))
(fx-init! (js-get (js-global) "__g1canvas"))
(define T (fx-target-mrt-msaa! 2 ${W} ${H} 4))
(display "SAMPLES ") (display (fx-target-samples T)) (newline)
(define tri
  (fx-program3!
   '((attribute vec2 a_pos)
     (uniform float u_z)
     (define (main) void (set! gl_Position (vec4 a_pos u_z (fl 1)))))
   '((precision highp float)
     (uniform vec4 u_c0)
     (uniform vec4 u_c1)
     (out 0 vec4 o_a)
     (out 1 vec4 o_b)
     (define (main) void (set! o_a u_c0) (set! o_b u_c1)))))
(define vbuf (fx-buffer!))
(define vb (fx-alloc! 24))
(%mem-f32-set! vb -1.0) (%mem-f32-set! (+ vb 4) -1.0)
(%mem-f32-set! (+ vb 8) 1.0) (%mem-f32-set! (+ vb 12) -1.0)
(%mem-f32-set! (+ vb 16) -1.0) (%mem-f32-set! (+ vb 20) 1.0)
(define obs (fx-target! ${W} ${H}))
(define see-colour
  (fx-fullscreen!
   '((precision highp float)
     (uniform sampler2D u_src)
     (uniform vec2 u_resolution)
     (define (main) void
       (set! gl_FragColor (texture2D u_src (/ gl_FragCoord.xy u_resolution)))))))
(define see-depth
  (fx-fullscreen!
   '((precision highp float)
     (uniform sampler2D u_src)
     (uniform vec2 u_resolution)
     (define (main) void
       (local vec4 t (texture2D u_src (/ gl_FragCoord.xy u_resolution)))
       (set! gl_FragColor (vec4 t.r t.r t.r (fl 1)))))))
(define out (fx-alloc! ${W * H * 4}))
(define (hex-of base n)
  (let loop ((i 0) (acc '()))
    (if (= i n)
        (list->string (reverse acc))
        (let* ((b (%mem-u8-ref (+ base i)))
               (h (string-ref "0123456789abcdef" (quotient b 16)))
               (l (string-ref "0123456789abcdef" (remainder b 16))))
          (loop (+ i 1) (cons l (cons h acc)))))))
(define (observe! q tex)
  (fx-bind-target! obs)
  (cmd-blend! 'off) (cmd-depth! #f) (cmd-depth-write! #t) (cmd-color-mask! #t #t #t #t)
  (fx-fullscreen-use! q 0.0)
  (cmd-bind-texture! 0 tex)
  (fx-uniform! (fx-quad-program q) 'u_src 0)
  (fx-fullscreen-draw! q)
  (cmd-read-pixels! 0 0 ${W} ${H} out)
  (cmd-flush!)
  (hex-of out ${W * H * 4}))
(define (cycle! k c0r c0g c0b c1r c1g c1b z)
  (cmd-begin!)
  (fx-bind-target! T)
  (cmd-blend! 'off) (cmd-depth! #t) (cmd-depth-write! #t) (cmd-depth-func! 'less)
  (cmd-clear! 0.0 0.0 0.0 0.0)
  (fx-use! tri vbuf)
  (cmd-buffer-data! vb 24)
  (fx-uniform! tri 'u_c0 c0r c0g c0b 1.0)
  (fx-uniform! tri 'u_c1 c1r c1g c1b 1.0)
  (fx-uniform! tri 'u_z z)
  (cmd-draw-arrays! GL-TRIANGLES 0 3)
  (fx-resolve! T)
  (cmd-flush!)
  (let* ((a (begin (cmd-begin!) (observe! see-colour (fx-mrt-texture T 0))))
         (b (begin (cmd-begin!) (observe! see-colour (fx-mrt-texture T 1))))
         (d (begin (cmd-begin!) (observe! see-depth (fx-target-depth-texture T)))))
    (display "C") (display k) (display " ") (display a) (display " ")
    (display b) (display " ") (display d) (newline)))
(define M (fx-target-mrt! 2 ${W} ${H}))
(cmd-begin!)
(fx-bind-target! M)
(cmd-blend! 'off) (cmd-depth! #t) (cmd-depth-write! #t) (cmd-depth-func! 'less)
(cmd-clear! 0.0 0.0 0.0 0.0)
(fx-use! tri vbuf)
(cmd-buffer-data! vb 24)
(fx-uniform! tri 'u_c0 0.5 0.5 0.5 1.0)
(fx-uniform! tri 'u_c1 0.5 0.5 0.5 1.0)
(fx-uniform! tri 'u_z 0.0)
(cmd-draw-arrays! GL-TRIANGLES 0 3)
(cmd-flush!)
(cmd-begin!)
(display "M ") (display (observe! see-depth (fx-target-depth-texture M))) (newline)
${CYCLES.map((c, k) => `(cycle! ${k} ${fl(c.c0[0])} ${fl(c.c0[1])} ${fl(c.c0[2])} ${fl(c.c1[0])} ${fl(c.c1[1])} ${fl(c.c1[2])} ${fl(c.z)})`).join('\n')}
`;

// the raw WebGL2 reference, run in the page after the program, on its context
const reference = `(samples) => {
  const canvas = globalThis.__g1canvas;
  const gl = canvas.getContext('webgl2');
  const W = ${W}, H = ${H};
  gl.getExtension('EXT_color_buffer_float') || gl.getExtension('EXT_color_buffer_half_float');
  const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; };
  const prog = (vs, fs) => { const p = gl.createProgram(); gl.attachShader(p, sh(gl.VERTEX_SHADER, vs));
    gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs)); gl.bindAttribLocation(p, 0, 'a_pos'); gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p)); return p; };
  const tri = prog('#version 300 es\\nin vec2 a_pos; uniform float u_z; void main(){ gl_Position = vec4(a_pos, u_z, 1.0); }',
    '#version 300 es\\nprecision highp float; uniform vec4 u_c0; uniform vec4 u_c1; layout(location = 0) out vec4 o_a; layout(location = 1) out vec4 o_b; void main(){ o_a = u_c0; o_b = u_c1; }');
  const quadVs = '#version 300 es\\nin vec2 a_pos; void main(){ gl_Position = vec4(a_pos, 0.0, 1.0); }';
  const seeColour = prog(quadVs, '#version 300 es\\nprecision highp float; uniform sampler2D u_src; out vec4 o; void main(){ o = texelFetch(u_src, ivec2(gl_FragCoord.xy), 0); }');
  const seeDepth = prog(quadVs, '#version 300 es\\nprecision highp float; uniform sampler2D u_src; out vec4 o; void main(){ float d = texelFetch(u_src, ivec2(gl_FragCoord.xy), 0).r; o = vec4(d, d, d, 1.0); }');
  const rb = (fmt) => { const r = gl.createRenderbuffer(); gl.bindRenderbuffer(gl.RENDERBUFFER, r);
    gl.renderbufferStorageMultisample(gl.RENDERBUFFER, samples, fmt, W, H); return r; };
  const tex = (ifmt, fmt, type) => { const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texImage2D(gl.TEXTURE_2D, 0, ifmt, W, H, 0, fmt, type, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE); return t; };
  const ms = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, ms);
  gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, rb(gl.RGBA16F));
  gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT1, gl.RENDERBUFFER, rb(gl.RGBA16F));
  gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, rb(gl.DEPTH_COMPONENT24));
  gl.drawBuffers([gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1]);
  const t0 = tex(gl.RGBA16F, gl.RGBA, gl.HALF_FLOAT), t1 = tex(gl.RGBA16F, gl.RGBA, gl.HALF_FLOAT);
  const td = tex(gl.DEPTH_COMPONENT24, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT);
  const rs = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, rs);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t0, 0);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT1, gl.TEXTURE_2D, t1, 0);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, td, 0);
  gl.drawBuffers([gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1]);
  const ot = tex(gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE);
  const ob = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, ob);
  gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, ot, 0);
  const vbuf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, vbuf);
  const vao = gl.createVertexArray(); gl.bindVertexArray(vao);
  gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 8, 0);
  const hex = a => Array.from(a, b => b.toString(16).padStart(2, '0')).join('');
  const observe = (p, t) => {
    gl.bindFramebuffer(gl.FRAMEBUFFER, ob); gl.viewport(0, 0, W, H);
    gl.disable(gl.BLEND); gl.disable(gl.DEPTH_TEST); gl.colorMask(true, true, true, true);
    gl.useProgram(p); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), gl.DYNAMIC_DRAW);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, t); gl.uniform1i(gl.getUniformLocation(p, 'u_src'), 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    const px = new Uint8Array(W * H * 4); gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, px); return hex(px); };
  const out = [];
  for (const c of ${JSON.stringify(CYCLES)}) {
    gl.bindFramebuffer(gl.FRAMEBUFFER, ms); gl.viewport(0, 0, W, H);
    gl.disable(gl.BLEND); gl.enable(gl.DEPTH_TEST); gl.depthMask(true); gl.depthFunc(gl.LESS);
    gl.clearColor(0, 0, 0, 0); gl.clearDepth(1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.useProgram(tri); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1]), gl.DYNAMIC_DRAW);
    gl.uniform4f(gl.getUniformLocation(tri, 'u_c0'), c.c0[0], c.c0[1], c.c0[2], 1);
    gl.uniform4f(gl.getUniformLocation(tri, 'u_c1'), c.c1[0], c.c1[1], c.c1[2], 1);
    gl.uniform1f(gl.getUniformLocation(tri, 'u_z'), c.z);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, ms); gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, rs);
    for (let i = 0; i < 2; i++) {
      gl.readBuffer(gl.COLOR_ATTACHMENT0 + i);
      gl.drawBuffers(i === 0 ? [gl.COLOR_ATTACHMENT0, gl.NONE] : [gl.NONE, gl.COLOR_ATTACHMENT1]);
      gl.blitFramebuffer(0, 0, W, H, 0, 0, W, H, gl.COLOR_BUFFER_BIT, gl.NEAREST);
    }
    gl.blitFramebuffer(0, 0, W, H, 0, 0, W, H, gl.DEPTH_BUFFER_BIT, gl.NEAREST);
    gl.drawBuffers([gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1]);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, ms); gl.readBuffer(gl.COLOR_ATTACHMENT0);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    out.push([observe(seeColour, t0), observe(seeColour, t1), observe(seeDepth, td)]);
  }
  return { out, error: gl.getError() };
}`;

function compileProgram() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-g1gpu-'));
    try {
        const ss = path.join(dir, 'p.ss'), js = path.join(dir, 'p.mjs');
        fs.writeFileSync(ss, program);
        const c = spawnSync(path.join(root, 'bin/goeteiac'), ['--js', ss, js], { cwd: root, encoding: 'utf8', timeout: 300000 });
        assert.ok(c.status === 0 && fs.existsSync(js), `not compiled: ${((c.stdout || '') + (c.stderr || '')).trim().split('\n').pop()}`);
        return fs.readFileSync(js).toString('base64');
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const pageExpr = src => `(async () => {
  const canvas = document.createElement('canvas'); canvas.width = ${W}; canvas.height = ${H};
  document.body.appendChild(canvas); globalThis.__g1canvas = canvas;
  // every multisampled renderbuffer the program allocates, with the count it asked for
  const allocated = [];
  const proto = WebGL2RenderingContext.prototype, orig = proto.renderbufferStorageMultisample;
  proto.renderbufferStorageMultisample = function (t, s, f, w, h) {
    allocated.push(this.getParameter(this.RENDERBUFFER_BINDING)); return orig.call(this, t, s, f, w, h); };
  const m = await import('data:text/javascript;base64,${src}');
  const bytes = [];
  const io = { write_byte: b => bytes.push(b), read_byte: () => -1, path_byte: () => {}, open_read: () => -1,
               open_write: () => -1, fread: () => -1, fwrite: () => {}, fclose: () => {} };
  let threw = null;
  try { await m.main(io); } catch (e) { threw = String(e && (e.message || e)); }
  proto.renderbufferStorageMultisample = orig;
  const text = String.fromCharCode(...bytes);
  if (threw) return { text, threw };
  const gl0 = canvas.getContext('webgl2');
  const rbSamples = allocated.map(rb => { gl0.bindRenderbuffer(gl0.RENDERBUFFER, rb); return gl0.getRenderbufferParameter(gl0.RENDERBUFFER, gl0.RENDERBUFFER_SAMPLES); });
  const sm = text.match(/SAMPLES (\\d+)/);
  const ref = (${reference})(sm ? Number(sm[1]) : 0);
  return { text, threw, ref, rbSamples };
})()`;

const byte = (hex, x, y, ch) => parseInt(hex.substr(((y * W + x) * 4 + ch) * 2, 2), 16);
const near = (got, want) => Math.abs(got - want) <= 1;

// A skip is allowed only for the refusals the constructor makes BEFORE it
// allocates anything, each saying the context lacks a capability.  Every
// other error -- above all "the multisampled framebuffer is not complete",
// which a context that has every capability can still raise when an
// attachment is set up wrong -- fails the row below.
const CAPABILITY_REFUSALS = [
    'needs a WebGL2 context',
    'needs EXT_color_buffer_float or EXT_color_buffer_half_float',
    'no sample count up to ',
];
const isCapabilityRefusal = threw =>
    /fx-target-mrt-msaa!/.test(threw)
    && CAPABILITY_REFUSALS.some(p => threw.includes(p));

test('CONTROL the skip predicate: capability refusals skip, an incomplete framebuffer does not', () => {
    const who = 'fx-target-mrt-msaa!: ';
    assert.ok(isCapabilityRefusal(who + 'needs a WebGL2 context, and this one is WebGL1'));
    assert.ok(isCapabilityRefusal(who + 'rendering RGBA16F needs EXT_color_buffer_float or EXT_color_buffer_half_float, and the context has neither'));
    assert.ok(isCapabilityRefusal(who + 'no sample count up to 4 is offered both by RGBA16F [] and by DEPTH_COMPONENT24 []'));
    assert.ok(!isCapabilityRefusal(who + 'the multisampled framebuffer is not complete (status 36182)'));
    assert.ok(!isCapabilityRefusal(who + 'the resolve framebuffer is not complete (status 36054)'));
    assert.ok(!isCapabilityRefusal(who + '2 attachments: MAX_DRAW_BUFFERS is 1 and MAX_COLOR_ATTACHMENTS 1'));
    assert.ok(!isCapabilityRefusal('the multisampled framebuffer is not complete'));
});

if (!findChrome()) {
    test('the multisampled MRT resolve on a real GPU', t => {
        t.skip('NOT EXERCISED HERE: no Chrome beside this tree; the resolve is not run on a real GL here');
    });
} else {
    const src = compileProgram();
    for (const flags of [undefined, ['--use-angle=swiftshader']]) {
        const name = flags ? 'swiftshader' : 'default backend';
        test(`${name}: the multisampled MRT resolve equals a same-context raw-WebGL resolve`, async t => {
            const r = await withBrowser(page => page.evaluateInNewPage(pageExpr(src)), { timeoutMs: 120000, flags });
            // only the constructor's own capability refusal is a skip; any other error fails below
            if (r.threw && isCapabilityRefusal(r.threw)) {
                t.skip(`NOT EXERCISED HERE (${name}): ${r.threw}`);
                return;
            }
            assert.equal(r.threw, null, `the program threw: ${r.threw}\n${r.text}`);
            const samples = Number((r.text.match(/SAMPLES (\d+)/) || [])[1]);
            assert.ok(samples > 1, `the target reports ${samples} samples`);
            assert.ok(r.rbSamples.length >= 3, `only ${r.rbSamples.length} multisampled renderbuffers were recorded`);
            r.rbSamples.forEach((n, i) => assert.equal(n, samples, `renderbuffer ${i}: the driver allocated ${n} samples, the target reports ${samples}`));
            const mline = r.text.split('\n').find(l => l.startsWith('M '));
            assert.ok(mline, `the single-sampled MRT printed nothing:\n${r.text}`);
            const md = mline.split(' ')[1];
            assert.ok(near(byte(md, 4, 4, 0), Math.round(0.5 * 255)), `single-sampled MRT depth interior: ${byte(md, 4, 4, 0)}`);
            assert.equal(byte(md, 28, 28, 0), 255, 'single-sampled MRT depth outside is not the cleared 1.0');
            assert.equal(r.ref.error, 0, `gl.getError() after the run: ${r.ref.error}`);
            CYCLES.forEach((c, k) => {
                const line = r.text.split('\n').find(l => l.startsWith(`C${k} `));
                assert.ok(line, `cycle ${k} printed nothing:\n${r.text}`);
                const [, a, b, d] = line.split(' ');
                const [ra, rb, rd] = r.ref.out[k];
                // analytic interiors: (4,4) is inside the triangle, (28,28) outside it
                for (let ch = 0; ch < 3; ch++) {
                    assert.ok(near(byte(a, 4, 4, ch), Math.round(c.c0[ch] * 255)), `cycle ${k} colour 0 interior channel ${ch}: ${byte(a, 4, 4, ch)}`);
                    assert.ok(near(byte(b, 4, 4, ch), Math.round(c.c1[ch] * 255)), `cycle ${k} colour 1 interior channel ${ch}: ${byte(b, 4, 4, ch)}`);
                    assert.equal(byte(a, 28, 28, ch), 0, `cycle ${k} colour 0 outside is not the clear colour`);
                }
                assert.ok(near(byte(d, 4, 4, 0), Math.round((c.z + 1) / 2 * 255)), `cycle ${k} depth interior: ${byte(d, 4, 4, 0)}`);
                assert.equal(byte(d, 28, 28, 0), 255, `cycle ${k} depth outside is not the cleared 1.0`);
                // the whole images against the reference
                assert.equal(a, ra, `cycle ${k}: colour 0 differs from the raw-WebGL resolve`);
                assert.equal(b, rb, `cycle ${k}: colour 1 differs from the raw-WebGL resolve`);
                assert.equal(d, rd, `cycle ${k}: depth differs from the raw-WebGL resolve`);
            });
        });
    }
}
