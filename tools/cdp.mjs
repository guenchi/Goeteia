// Copyright 2026 guenchi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Drive a real browser over the DevTools protocol, so that a shader can
// be handed to a real GLSL compiler and a page can be made to really
// draw.
//
// Why this exists: the page verifier's GL is a recording stub --
// rt/verify.mjs has `compileShader() {}` and `getShaderParameter: () =>
// true` -- so every shader "compiles" there and an invalid one passes
// every page test with draws counted and frames animated.  A check that
// answers yes to everything is worse than no check: without one people
// stay careful.  What a real browser adds over a shader compiler alone
// is the other half of the question -- it links the program and runs
// the draw, so "does this compile" and "does this page produce pixels"
// are answered by one instrument.
//
// Measured on this machine (2026-09-09), which is why the probe order
// below is what it is:
//
//   Google Chrome 152 / Chrome for Testing 141, --headless=new
//       -> webgl2, ANGLE Metal on the real GPU; a legal shader
//          compiles, a program links, a triangle reads back green
//   chrome-headless-shell 141
//       -> getContext('webgl2') returns NULL: no context at all
//
// !! The smallest, fastest binary is the one that does not work.  Do
// not "simplify" this to chrome-headless-shell: it would not fail, it
// would pass everything, which is the stub all over again.
//
// No npm dependency: node's built-in WebSocket speaks CDP directly.
//
// Usage:
//   node tools/cdp.mjs            run the self-check
//   GOETEIA_CHROME=/path/to/bin   use that binary instead of probing
//   GOETEIA_CHROME=none           force the absent path (for testing it)

import { spawn, execFileSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

// ---- which browser, and saying so ----
//
// The version is printed on every run rather than asserted.  An
// assertion on it would turn every browser update into a false red;
// printing it makes an update show up as CHANGED TEXT in the log, the
// way the gate reader derives its counts from the log instead of
// keeping expected constants that silently stop matching.
export function findChrome() {
    const override = process.env.GOETEIA_CHROME;
    if (override === 'none') return null;
    if (override) {
        return isExecutable(override) ? describe(override) : null;
    }
    for (const c of candidates()) if (isExecutable(c)) return describe(c);
    return null;
}

function candidates() {
    const home = os.homedir();
    const out = [];
    // A pinned version first: it is decoupled from the browser the
    // person is using and from its updates.  It is only ever a
    // preference, never a requirement -- it lives in a cache directory
    // that nothing maintains, so its absence must cost nothing.
    const cache = path.join(home, '.cache', 'puppeteer', 'chrome');
    if (fs.existsSync(cache)) {
        for (const v of fs.readdirSync(cache).sort().reverse()) {
            const app = path.join(cache, v);
            for (const dir of safeReaddir(app)) {
                out.push(path.join(app, dir, 'Google Chrome for Testing.app',
                                   'Contents', 'MacOS', 'Google Chrome for Testing'));
                out.push(path.join(app, dir, 'chrome'));           // linux layout
            }
        }
    }
    out.push('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome');
    out.push(path.join(home, 'Applications', 'Google Chrome.app',
                       'Contents', 'MacOS', 'Google Chrome'));
    out.push('/usr/bin/google-chrome');
    out.push('/usr/bin/chromium');
    // deliberately NOT chrome-headless-shell -- see the header
    return out;
}

const safeReaddir = d => { try { return fs.readdirSync(d); } catch { return []; } };
const isExecutable = p => { try { fs.accessSync(p, fs.constants.X_OK); return true; } catch { return false; } };

function describe(bin) {
    // The version is the whole of the drift-visibility rule, so a
    // failure to read it is REPORTED, not smoothed over: an earlier
    // draft caught the error and printed "(version unavailable)", which
    // read like a harmless quirk while the log quietly stopped carrying
    // the one thing that makes a browser update visible.
    let version;
    try {
        version = execFileSync(bin, ['--version'],
                               { encoding: 'utf8', timeout: 10000 }).trim();
    } catch (e) {
        version = `!! could not read --version: ${e.message}`;
    }
    return { path: bin, version };
}

// ---- one browser process, many pages ----
//
// Launching costs 0.6s (installed Chrome) to 2.1s (Chrome for Testing)
// on this machine, and that is PER PROCESS.  A caller with twenty
// shaders to check opens twenty pages on one browser, not twenty
// browsers.
export async function withBrowser(fn, { timeoutMs = 30000 } = {}) {
    const found = findChrome();
    if (!found) throw new NoBrowser();
    const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-cdp-'));
    const proc = spawn(found.path, [
        '--headless=new', '--remote-debugging-port=0',
        `--user-data-dir=${profile}`, '--no-first-run',
        '--no-default-browser-check', '--disable-extensions',
        // Without these the browser asks the macOS Keychain for its
        // password-encryption key, and that ASKS THE USER: the launch
        // sits behind a GUI prompt nobody is there to answer, prints
        // `Keychain lookup failed ... userCanceledErr (-128)`, and
        // reaches the DevTools line late or never.  Measured here as a
        // launch that produced no endpoint inside 30s -- an instrument
        // that stalls on a dialog is not one a gate can wait on.
        '--use-mock-keychain', '--password-store=basic',
        // it is a shader compiler to us, not a browser: no first-run
        // network chatter to sit behind either
        '--disable-sync', '--disable-background-networking',
        'about:blank',
    ]);
    // Everything the browser says is kept, so that a launch which never
    // reaches the endpoint can be diagnosed from the error instead of
    // being written off as flaky.  An unexplained intermittent red
    // teaches people to ignore the gate.
    let chatter = '';
    // An instrument that hangs is worse than one that fails: it stalls
    // whatever is waiting on it and reads as "still going".  Every wait
    // below is bounded.
    const kill = () => { try { proc.kill('SIGKILL'); } catch { /* already gone */ } };
    const guard = setTimeout(kill, timeoutMs);
    if (guard.unref) guard.unref();   // a watchdog must not itself keep node alive
    try {
        const endpoint = await readEndpoint(proc, timeoutMs, t => { chatter += t; });
        const session = await connect(endpoint, timeoutMs);
        try {
            return await fn({ ...session, browser: found });
        } finally {
            session.close();
        }
    } finally {
        clearTimeout(guard);
        kill();
        discardProfile(profile);
    }
}

// Remove the throwaway profile directory, and never throw doing it.
//
// This runs in a `finally`, and a `finally` that throws replaces
// whatever the body produced.  So a failure here does two things, and
// the second is the worse one: it can turn a passing test red, and it
// can swallow a real failure and report itself in its place.  A
// teardown must not be able to author a verdict.
//
// `force: true` does not cover this.  It suppresses ENOENT, not the
// EACCES/ENOTEMPTY that a just-SIGKILLed Chrome produces while the
// kernel is still tearing down its open files -- observed once in 49
// gate runs, on 2026-09-09, where it failed a shader test that had
// already compiled its shaders successfully.
export function discardProfile(profile) {
    for (let attempt = 0; attempt < 5; attempt++) {
        try { fs.rmSync(profile, { recursive: true, force: true }); return; }
        catch (e) {
            if (attempt === 4) {
                // Loud, because the alternative to reporting this is a
                // temp directory that quietly accumulates one copy per
                // run, and because a reader who sees the test pass is
                // entitled to know something did not get cleaned up.
                process.stderr.write(
                    `cdp: could not remove ${profile}: ${e.code || e.message}\n`);
                return;
            }
            const until = Date.now() + 100;
            while (Date.now() < until) { /* the kill is asynchronous; give it a moment */ }
        }
    }
}

export class NoBrowser extends Error {
    constructor() { super('no Chrome binary found'); this.name = 'NoBrowser'; }
}

function readEndpoint(proc, timeoutMs, note = () => {}) {
    return new Promise((resolve, reject) => {
        let buf = '';
        const t = setTimeout(() => reject(new Error(
            'the browser printed no DevTools endpoint in ' + timeoutMs + 'ms; it said: ' +
            (buf.trim().split('\n').slice(-4).join(' | ') || '(nothing at all)'))), timeoutMs);
        const take = d => {
            buf += d; note(String(d));
            const m = buf.match(/ws:\/\/\S+/);
            if (m) { clearTimeout(t); resolve(m[0]); }
        };
        proc.stderr.on('data', take);
        // some builds put the line on stdout; watching one stream only
        // is a failure mode that looks exactly like a slow launch
        proc.stdout.on('data', take);
        proc.on('exit', code => {
            clearTimeout(t);
            reject(new Error(`the browser exited before listening (code ${code})`));
        });
    });
}

async function connect(endpoint, timeoutMs) {
    const sock = new WebSocket(endpoint);
    await withTimeout(new Promise((res, rej) => {
        sock.addEventListener('open', res);
        sock.addEventListener('error', () => rej(new Error('could not open the DevTools socket')));
    }), timeoutMs, 'opening the DevTools socket');
    let nextId = 0;
    const waiting = new Map();
    sock.addEventListener('message', ev => {
        const m = JSON.parse(ev.data);
        if (m.id && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); }
    });
    const send = (method, params = {}, sessionId) => withTimeout(
        new Promise(res => {
            const id = ++nextId;
            waiting.set(id, res);
            sock.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
        }), timeoutMs, method);

    // Each page is its own target on this one browser process.
    async function evaluateInNewPage(expression) {
        const { result: target } = await send('Target.createTarget', { url: 'about:blank' });
        try {
            const { result: att } = await send(
                'Target.attachToTarget', { targetId: target.targetId, flatten: true });
            const reply = await send('Runtime.evaluate', {
                expression, returnByValue: true, awaitPromise: true,
            }, att.sessionId);
            if (reply.result?.exceptionDetails) {
                throw new Error('the page threw: ' +
                    (reply.result.exceptionDetails.exception?.description ??
                     reply.result.exceptionDetails.text));
            }
            return reply.result?.result?.value;
        } finally {
            await send('Target.closeTarget', { targetId: target.targetId })
                .catch(() => { /* the browser is about to be killed anyway */ });
        }
    }
    return { evaluateInNewPage, close: () => sock.close() };
}

// The timer is CLEARED once the race is decided.  Leaving it pending
// keeps node's event loop alive until it fires, so every run sat for
// the full timeout after its work was done: the self-check printed
// "ok" and then the process hung about for 30s.  Nothing failed, so
// nothing said anything -- it just looked like a slow instrument, and
// a slow gate is one people stop running.
function withTimeout(p, ms, what) {
    let timer;
    const bell = new Promise((_, rej) => {
        timer = setTimeout(() => rej(new Error(`timed out after ${ms}ms: ${what}`)), ms);
    });
    return Promise.race([p, bell]).finally(() => clearTimeout(timer));
}

// ---- the question this tool exists to answer ----
//
// Returns, for one vertex/fragment pair: whether each shader compiled,
// the compiler's own log, whether the program linked, and -- when it
// did -- the pixel at the centre after drawing a full-screen triangle.
export function shaderProbe(vertexSrc, fragmentSrc) {
    return `(() => {
  const c = document.createElement('canvas'); c.width = 8; c.height = 8;
  const gl = c.getContext('webgl2') || c.getContext('webgl');
  if (!gl) return { context: null };
  const dbg = gl.getExtension('WEBGL_debug_renderer_info');
  const build = (kind, src) => {
    const s = gl.createShader(kind);
    gl.shaderSource(s, src); gl.compileShader(s);
    return { shader: s,
             ok: !!gl.getShaderParameter(s, gl.COMPILE_STATUS),
             log: (gl.getShaderInfoLog(s) || '').trim() };
  };
  const vs = build(gl.VERTEX_SHADER, ${JSON.stringify(vertexSrc)});
  const fs = build(gl.FRAGMENT_SHADER, ${JSON.stringify(fragmentSrc)});
  const out = {
    context: (typeof WebGL2RenderingContext !== 'undefined' &&
              gl instanceof WebGL2RenderingContext) ? 'webgl2' : 'webgl1',
    renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL)
                  : gl.getParameter(gl.RENDERER),
    vertex: { ok: vs.ok, log: vs.log },
    fragment: { ok: fs.ok, log: fs.log },
    linked: false, pixel: null,
  };
  if (!vs.ok || !fs.ok) return out;
  const p = gl.createProgram();
  gl.attachShader(p, vs.shader); gl.attachShader(p, fs.shader); gl.linkProgram(p);
  out.linked = !!gl.getProgramParameter(p, gl.LINK_STATUS);
  out.linkLog = (gl.getProgramInfoLog(p) || '').trim();
  if (!out.linked) return out;
  gl.useProgram(p);
  const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(p, 'a_pos');
  if (loc >= 0) {
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  }
  gl.viewport(0, 0, 8, 8);
  gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  const px = new Uint8Array(4);
  gl.readPixels(4, 4, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
  out.pixel = Array.from(px);
  return out;
})()`;
}

export async function checkShader(page, vertexSrc, fragmentSrc) {
    return page.evaluateInNewPage(shaderProbe(vertexSrc, fragmentSrc));
}

// ---- reading a whole frame back, and comparing two of them ----
//
// The pixel above is one pixel: enough to say "something was drawn",
// not enough to say "this render and that one differ, and here".  The
// questions parked as deferred -- an occlusion query that must actually
// hide something, a reflection that must change when the surface moves,
// a screen-space effect that must darken a corner -- are all of the
// form "render, change one thing, render again, and see the
// difference".  Until something could read a frame back, none of them
// had a criterion, and writing the effect first would have been writing
// code nobody could judge.
//
// The comparison happens INSIDE the page.  Two 256x256 frames are
// half a megabyte of JSON if they come back raw, and -- the part that
// matters more -- two frames read back separately have travelled
// through two different moments of GPU and driver state.  Drawing both
// into one context and subtracting there asks the question that was
// meant.
//
// What comes back is deliberately small and deliberately not just a
// verdict: a fingerprint for identity, a count and a maximum for size,
// and a coarse map for location.  A probe that answered only "they
// differ" would be unable to tell a real difference from a broken
// probe, and there would be nothing to calibrate.
//
// Each of the three has a different floor, and a cell should say
// which one it is leaning on:
//
//   fingerprint  changes for ANY changed byte.  One pixel, one channel,
//                one unit -- it moves.  It says nothing about how
//                much or where, and two different frames could in
//                principle collide (this is FNV-1a, a fingerprint, not
//                a cryptographic hash: crypto.subtle is async and this
//                probe is a single synchronous expression).
//   differing    exact count of pixels that differ at all.  Its floor
//                is one pixel -- measured, in the self-check below.
//   grid         a coarse map, 8x8 cells of mean absolute difference.
//                Its resolution is (delta / cell area): in a 64x64
//                frame a cell covers 64 pixels, so ONE pixel changed by
//                d shows as round(d/64) -- a full-contrast pixel reads
//                4 (measured in the self-check, which prints it), and
//                anything under d = 32 rounds to 0 and disappears.
//                So the grid LOCATES a difference that `differing`
//                has already established; it must not be used to decide
//                whether there is one.
// The fingerprint FUNCTION, not an application of it: the first
// version took the byte expression as an argument and produced
// `((b) => ...)(b)`, which the page evaluated as a self-reference and
// refused.  It is a function here because both frames are hashed.
const FNV1A = `((b) => { let h = 0x811c9dc5;
  for (let i = 0; i < b.length; i++) { h ^= b[i]; h = (h * 0x01000193) >>> 0; }
  return h.toString(16).padStart(8, '0'); })`;

export function frameDiffProbe(drawA, drawB, { width = 64, height = 64 } = {}) {
    return `(() => {
  const W = ${width}, H = ${height};
  const c = document.createElement('canvas'); c.width = W; c.height = H;
  const gl = c.getContext('webgl2') || c.getContext('webgl');
  if (!gl) return { context: null };
  const read = () => { const p = new Uint8Array(W * H * 4);
                       gl.readPixels(0, 0, W, H, gl.RGBA, gl.UNSIGNED_BYTE, p); return p; };
  const hash = ${FNV1A};
  const draw = (src) => {
    gl.viewport(0, 0, W, H);
    gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    (new Function('gl', 'W', 'H', src))(gl, W, H);
    return read();
  };
  let a, b;
  try { a = draw(${JSON.stringify(drawA)}); b = draw(${JSON.stringify(drawB)}); }
  catch (e) { return { context: 'error', error: String(e && e.message || e) }; }
  let differing = 0, maxDelta = 0;
  const G = 8, grid = new Array(G * G).fill(0), cells = new Array(G * G).fill(0);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      let d = 0;
      for (let k = 0; k < 4; k++) { const v = Math.abs(a[i+k] - b[i+k]); if (v > d) d = v; }
      if (d > 0) differing++;
      if (d > maxDelta) maxDelta = d;
      const g = ((y * G / H) | 0) * G + ((x * G / W) | 0);
      grid[g] += d; cells[g]++;
    }
  }
  return {
    context: (typeof WebGL2RenderingContext !== 'undefined' &&
              gl instanceof WebGL2RenderingContext) ? 'webgl2' : 'webgl1',
    width: W, height: H, pixels: W * H,
    hashA: hash(a), hashB: hash(b),
    same: hash(a) === hash(b),
    differing, maxDelta,
    grid: grid.map((s, i) => Math.round(s / cells[i])),
  };
})()`;
}

export async function diffFrames(page, drawA, drawB, opts) {
    return page.evaluateInNewPage(frameDiffProbe(drawA, drawB, opts));
}

// ---- the self-check ----
//
// The first case is the reason the tool exists: a shader that MUST be
// refused.  If it ever passes, what we are talking to is a stub again,
// and every other green here means nothing.  The second is its
// opposite: legal source that must compile, link and put pixels on the
// screen -- without it, "refused everything" would also look like
// success.
const LEGAL_VS = 'attribute vec2 a_pos; void main(){ gl_Position = vec4(a_pos, 0.0, 1.0); }';
const LEGAL_FS = 'void main(){ gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }';
const TYPE_ERROR_VS = 'void main(){ int n = 1.0; gl_Position = vec4(0.0); }';

async function selfCheck() {
    const found = findChrome();
    if (!found) {
        // Absence is announced in the vocabulary run-tests.sh lifts out
        // of a test's output and the gate reader counts, so a stood-down
        // check appears in the summary instead of vanishing.
        console.log('NOT EXERCISED HERE (no Chrome binary beside this tree; ' +
                    'the shader-compile and render checks stand down)');
        return 0;
    }
    console.log(`browser: ${found.path}`);
    console.log(`version: ${found.version}`);
    const problems = [];
    await withBrowser(async page => {
        const legal = await checkShader(page, LEGAL_VS, LEGAL_FS);
        console.log(`context: ${legal.context}   renderer: ${legal.renderer}`);
        if (!legal.context) problems.push('no WebGL context at all');
        if (!legal.vertex.ok) problems.push(`a legal vertex shader was refused: ${legal.vertex.log}`);
        if (!legal.fragment.ok) problems.push(`a legal fragment shader was refused: ${legal.fragment.log}`);
        if (!legal.linked) problems.push(`a legal program did not link: ${legal.linkLog}`);
        const px = legal.pixel;
        if (!px || px[0] !== 0 || px[1] !== 255 || px[2] !== 0) {
            problems.push(`the drawn pixel was ${JSON.stringify(px)}, not green`);
        } else {
            console.log(`drew a triangle and read back ${JSON.stringify(px)}`);
        }

        // ---- the frame probe, calibrated ----
        //
        // Three cases, because the useful thing about this probe is
        // not that it can say "different" -- it is the SIZE of the
        // smallest difference it can see, and that is a measurement,
        // not a design claim.
        const CLEAR = (r, g_, b) => `gl.clearColor(${r},${g_},${b},1);`
            + ' gl.clear(gl.COLOR_BUFFER_BIT);';
        const ONE_PIXEL = CLEAR(0, 1, 0)
            + ' gl.enable(gl.SCISSOR_TEST); gl.scissor(3,3,1,1);'
            + ' gl.clearColor(1,0,0,1); gl.clear(gl.COLOR_BUFFER_BIT);'
            + ' gl.disable(gl.SCISSOR_TEST);';
        const same = await diffFrames(page, CLEAR(0, 1, 0), CLEAR(0, 1, 0));
        if (!same.context) problems.push('the frame probe got no WebGL context');
        else if (!same.same || same.differing !== 0)
            problems.push(`two identical draws came back as ${same.differing} `
                          + 'differing pixel(s) -- the probe sees changes that are not there');
        const one = await diffFrames(page, CLEAR(0, 1, 0), ONE_PIXEL);
        if (one.differing !== 1 || one.same)
            problems.push(`a one-pixel change read as ${one.differing} differing `
                          + `pixel(s) and same=${one.same}; the floor is not one pixel`);
        else
            console.log(`frame diff: one changed pixel is visible `
                        + `(${one.width}x${one.height}, max delta ${one.maxDelta})`);
        const all = await diffFrames(page, CLEAR(0, 0, 0), CLEAR(1, 1, 1));
        if (all.differing !== all.pixels || all.maxDelta !== 255)
            problems.push(`black against white read as ${all.differing} of `
                          + `${all.pixels} pixels, max delta ${all.maxDelta}`);
        // The grid's resolution, printed rather than asserted -- and
        // then a case that measures where it gives up.  `differing`
        // exists separately precisely because the grid has a floor, and
        // the number belongs next to the claim rather than in a comment
        // that could drift away from it.
        const FAINT = CLEAR(0, 1, 0)
            + ' gl.enable(gl.SCISSOR_TEST); gl.scissor(3,3,1,1);'
            + ' gl.clearColor(0,0.996,0,1); gl.clear(gl.COLOR_BUFFER_BIT);'
            + ' gl.disable(gl.SCISSOR_TEST);';
        const faint = await diffFrames(page, CLEAR(0, 1, 0), FAINT);
        console.log(`frame diff: one full-contrast pixel reads `
                    + `${Math.max(...one.grid)} in its 8x8 cell; a faint one `
                    + `(delta ${faint.maxDelta}) reads `
                    + `${Math.max(...faint.grid)} while differing says `
                    + `${faint.differing}`);
        if (faint.differing < 1)
            problems.push('a faint one-pixel change was invisible to `differing` too, '
                          + 'so the exact count has a floor above one unit');

        const bad = await checkShader(page, TYPE_ERROR_VS, LEGAL_FS);
        if (bad.vertex.ok) {
            problems.push('`int n = 1.0;` COMPILED -- this is a stub, not a compiler');
        } else if (!/\d+:\d+|\d+/.test(bad.vertex.log)) {
            problems.push(`the refusal carried no line number: ${bad.vertex.log}`);
        } else {
            console.log(`refused \`int n = 1.0;\` -- ${bad.vertex.log.split('\n')[0]}`);
        }
    });
    if (problems.length) {
        for (const p of problems) console.log(`  FAIL ${p}`);
        return 1;
    }
    console.log('self-check ok');
    return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
    // Exit with the VERDICT.  A script that ends on its last incidental
    // command reports that command's status, and a caller reading it
    // gets a green that means "the cleanup worked".
    process.exitCode = await selfCheck().catch(e => {
        console.log(`  FAIL ${e.message}`);
        return 1;
    });
}
