// (gfx raster) differential harness: the Goeteia rasterizer against the
// Python reference implementation it was ported from, on one and the
// same mesh and one and the same cameras, compared byte for byte.
//
// Why a .mjs and not another test/*.ss: the oracle is a second program
// in a second language, so the comparison has to happen outside both.
// The Scheme side is a probe compiled on the fly (below) that reads its
// mesh, its cameras and its viewport from stdin and writes back a mask
// per camera; the Python side is a driver (also written below) that
// asks rasterlib for the same masks.  Neither one knows what the other
// answered.
//
// Three sections:
//   A  self-contained: a procedurally generated mesh through the Wasm
//      backend and the JS backend, whose masks must be identical, and
//      whose silhouette must equal the one the full visibility buffer
//      produces.  This section never skips.
//   B  the Python oracle, on the real asset and the real fixture
//      cameras.  Skipped, loudly, when the reference tree is absent --
//      it is not part of this repository.
//   C  timing, same 256x256 mask on both sides.
//
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFileSync, spawnSync } from 'child_process';
import { fileURLToPath } from 'url';
import { runModule } from '../rt/run.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-raster-'));

let fail = 0;
const check = (ok, what) => {
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${what}`);
    if (!ok) fail = 1;
};

// ---------------------------------------------------------------- probe
//
// The header is read back out of staging memory with %mem-i32-ref and
// %mem-f64-ref rather than reassembled from bytes in Scheme: the bytes
// are already in the module's linear memory, and decoding them by hand
// would be a second, untested implementation of "little endian".

const PROBE = String.raw`
(import (rnrs) (gfx raster))

(define IN 65536)
(define limit (* 65536 (%mem-size)))
(define (need! end)
  (when (> end limit)
    (%mem-grow (+ 16 (quotient (- end limit) 65536)))
    (set! limit (* 65536 (%mem-size)))))

(define nin
  (let loop ((i 0))
    (let ((b (%read-byte)))
      (if (< b 0)
          i
          (begin (need! (+ IN i 1))
                 (%mem-u8-set! (+ IN i) b)
                 (loop (+ i 1)))))))

(define (i32 o) (%mem-i32-ref (+ IN o)))
(define nverts (i32 0))
(define nidx (i32 4))
(define ncams (i32 8))
(define reps (i32 12))
(define dump (i32 16))
(define check-frame (i32 20))
(define camoff 24)
(define posoff (+ camoff (* ncams 112)))
(define idxoff (+ posoff (* nverts 12)))
(define (camf i k) (%mem-f64-ref (+ IN camoff (* i 112) (* k 8))))
(define (cam-of i)
  (make-rcam (camf i 0) (camf i 1) (camf i 2) (camf i 3) (camf i 4)
             (camf i 5) (camf i 6) (camf i 7) (camf i 8) (camf i 9)
             (camf i 10) (camf i 11)))
(define (cam-w i) (%fl->fx (camf i 12)))
(define (cam-h i) (%fl->fx (camf i 13)))

(define mesh
  (make-rmesh (rattr-f32 (+ IN posoff) 12 0 nverts 3)
              (ridx-u32 (+ IN idxoff) nidx)))

(define heap (+ IN nin 64))
(define (alloc! n)
  (let* ((r (remainder heap 8))
         (base (if (= r 0) heap (+ heap (- 8 r))))
         (end (+ base n)))
    (need! end)
    (set! heap end)
    base))

;; FNV-1a over 32 bits, carried as two 16-bit halves: the multiplier
;; wraps modulo 2^32, and a fixnum here stops short of 2^30, so the
;; product is assembled from partial products that each stay inside
;; the range.  Written this way it is the standard hash, byte for byte
;; what Python computes, and not a private checksum.
(define (fnv-step hi lo b)
  (let* ((x (bitwise-xor lo b))
         (t0 (* x 403))
         (t1 (+ (* x 256) (* hi 403)))
         (nl (remainder t0 65536))
         (nh (remainder (+ t1 (quotient t0 65536)) 65536)))
    (cons nh nl)))

(define (fnv base n)
  (let loop ((i 0) (hi 33052) (lo 40389))
    (if (= i n)
        (cons hi lo)
        (let ((h (fnv-step hi lo (%mem-u8-ref (+ base i)))))
          (loop (+ i 1) (car h) (cdr h))))))

(define (say-hash tag i base n covered)
  (let ((h (fnv base n)))
    (display tag) (display " ") (display i)
    (display " fnv ") (display (car h)) (display " ") (display (cdr h))
    (display " covered ") (display covered)
    (newline)))

;; The mask is blind to everything the interpolation does inside a
;; triangle -- a swapped barycentric numerator leaves it untouched --
;; so the frame's depth and weights are streamed too, as integers so
;; that both sides print exactly what they computed.  1/depth is
;; quantised at 2^24 and each weight at 2^26; a disagreement is then
;; reported in those units instead of being rounded away.
(define (round->fx v)
  (%fl->fx (flfloor (fl+ v 0.5))))

(define (dump-frame fr i w h)
  (let ((b (make-vector 3 0.0)))
    (display "dep ") (display i) (display " ")
    (let rows ((y 0))
      (when (< y h)
        (let cols ((x 0))
          (when (< x w)
            (when (<= 0 (frame-tri fr x y))
              (display (round->fx (fl* (frame-invd fr x y) 16777216.0)))
              (display " "))
            (cols (+ x 1))))
        (rows (+ y 1))))
    (newline)
    (display "bar ") (display i) (display " ")
    (let rows ((y 0))
      (when (< y h)
        (let cols ((x 0))
          (when (< x w)
            (when (frame-bary! fr x y b)
              (display (round->fx (fl* (vector-ref b 0) 67108864.0)))
              (display " ")
              (display (round->fx (fl* (vector-ref b 1) 67108864.0)))
              (display " ")
              (display (round->fx (fl* (vector-ref b 2) 67108864.0)))
              (display " "))
            (cols (+ x 1))))
        (rows (+ y 1))))
    (newline)))

(define (dump-mask base n)
  (let loop ((i 0))
    (when (< i n)
      (%write-byte (+ 48 (%mem-u8-ref (+ base i))))
      (loop (+ i 1))))
  (newline))

(define scratch (alloc! (raster-scratch-bytes nverts)))

(let cams ((i 0))
  (when (< i ncams)
    (let* ((w (cam-w i)) (h (cam-h i)) (n (* w h))
           (c (cam-of i))
           (mark heap)
           (mk (make-rmask w h (alloc! (rmask-bytes w h))))
           (covered
            (let rep ((r 0) (last 0))
              (if (< r reps)
                  (rep (+ r 1) (render-mask! mk mesh c scratch))
                  last))))
      (say-hash "cam" i (rmask-base mk) n covered)
      (when (= dump 1) (dump-mask (rmask-base mk) n))
      (when (= check-frame 1)
        (let* ((fr (make-rframe w h (alloc! (rframe-bytes w h))))
               (mk2 (make-rmask w h (alloc! (rmask-bytes w h)))))
          (render-frame! fr mesh c scratch)
          (let ((cov2 (frame-mask! fr mk2)))
            (say-hash "frm" i (rmask-base mk2) n cov2))
          (when (= dump 1) (dump-frame fr i w h))))
      (set! heap mark))
    (cams (+ i 1))))
`;

// -------------------------------------------------------- probe input

function buildInput(nverts, positions, indices, cams, opts) {
    const ncams = cams.length;
    const head = 24 + ncams * 112;
    const buf = Buffer.alloc(head + nverts * 12 + indices.length * 4);
    buf.writeInt32LE(nverts, 0);
    buf.writeInt32LE(indices.length, 4);
    buf.writeInt32LE(ncams, 8);
    buf.writeInt32LE(opts.reps ?? 1, 12);
    buf.writeInt32LE(opts.dump ? 1 : 0, 16);
    buf.writeInt32LE(opts.checkFrame ? 1 : 0, 20);
    cams.forEach((c, i) => {
        const o = 24 + i * 112;
        const v = [c.az, c.el, c.dist, c.roll, c.fov,
                   c.target[0], c.target[1], c.target[2],
                   c.shift_u, c.shift_v, c.near, c.far, c.w, c.h];
        v.forEach((x, k) => buf.writeDoubleLE(x, o + k * 8));
    });
    for (let i = 0; i < nverts * 3; i++)
        buf.writeFloatLE(positions[i], head + i * 4);
    for (let i = 0; i < indices.length; i++)
        buf.writeUInt32LE(indices[i], head + nverts * 12 + i * 4);
    return buf;
}

function parseProbe(text) {
    const out = { hashes: new Map(), masks: new Map(), streams: new Map() };
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
        const s = /^(dep|bar) (\d+) (.*)$/.exec(lines[i]);
        if (s) {
            out.streams.set(`${s[1]}${s[2]}`, s[3].trim());
            continue;
        }
        const m = /^(cam|frm|grid) (\d+) fnv (\d+) (\d+) covered (\d+)$/.exec(lines[i]);
        if (!m) continue;
        const key = `${m[1]}${m[2]}`;
        out.hashes.set(key, { hi: +m[3], lo: +m[4], covered: +m[5] });
        if (/^[01]+$/.test(lines[i + 1] || '')) out.masks.set(key, lines[++i]);
    }
    return out;
}

// ------------------------------------------------------------ compile

const wasmPath = path.join(TMP, 'probe.wasm');
const jsPath = path.join(TMP, 'probe.js');
const probeSrc = path.join(TMP, 'probe.ss');
fs.writeFileSync(probeSrc, PROBE);
try {
    execFileSync(path.join(REPO, 'bin', 'goeteiac'), [probeSrc, wasmPath],
                 { stdio: 'pipe' });
    execFileSync(path.join(REPO, 'bin', 'goeteiac'),
                 ['--js', probeSrc, jsPath], { stdio: 'pipe' });
} catch (e) {
    console.log('FAIL probe does not compile');
    console.log(String(e.stdout || '') + String(e.stderr || ''));
    process.exit(1);
}

const wasmBytes = fs.readFileSync(wasmPath);

async function runWasm(input) {
    const { text } = await runModule(wasmBytes, input);
    return parseProbe(text);
}

function runJsBackend(input) {
    const inPath = path.join(TMP, 'in.bin');
    fs.writeFileSync(inPath, input);
    const r = spawnSync(process.execPath,
                        [path.join(REPO, 'rt', 'runjs.mjs'), jsPath, inPath],
                        { encoding: 'utf8', maxBuffer: 1 << 28 });
    if (r.status !== 0) throw new Error(r.stderr);
    return parseProbe(r.stdout);
}

// ============================================ A. self-contained fixture
//
// A crumpled grid, generated here so this section depends on nothing
// outside the repository.  The vertex positions are exactly
// representable as f32 (they are eighths), so nothing is lost writing
// them into the probe's input.

const GRID_N = 33;

function crumpledGrid(n) {
    const pos = [], idx = [];
    for (let j = 0; j < n; j++)
        for (let i = 0; i < n; i++) {
            pos.push((i * 5 - 2 * n) / 8, (j * 5 - 2 * n) / 8,
                     ((((i * 37 + j * 17) * 29) % 61) - 30) / 8);
        }
    for (let j = 0; j < n - 1; j++)
        for (let i = 0; i < n - 1; i++) {
            const a = j * n + i;
            idx.push(a, a + 1, a + n, a + 1, a + n + 1, a + n);
        }
    return { nverts: n * n, pos, idx };
}

// The masks the reference implementation produces for the grid above,
// pinned so that section A has an oracle and not merely two copies of
// this code agreeing with each other.  They are not left frozen: when
// the reference tree is present, section B recomputes them from it and
// compares, so a stale literal here shows up as a failure rather than
// as a check that silently stopped meaning anything.
const GRID_GOLDEN = [
    [12936, 16226, 1527],   // fnv hi, fnv lo, pixels covered
    [53999, 56803, 2864],
    [45801, 61292, 4487],
    [50665, 50380, 9015],
];

const gridCams = [
    { az: 0, el: 0, dist: 60, roll: 0, fov: 45, target: [0, 0, 0],
      shift_u: 0, shift_v: 0, near: 0.06, far: 6000, w: 96, h: 96 },
    { az: 35, el: 15, dist: 44, roll: 12, fov: 45, target: [0, 0, 0],
      shift_u: 1.5, shift_v: -2, near: 0.044, far: 4400, w: 128, h: 96 },
    { az: -72, el: -22, dist: 38, roll: 0, fov: 35, target: [0, 0, 0],
      shift_u: 0, shift_v: 0, near: 0.038, far: 3800, w: 64, h: 112 },
    { az: 155, el: 8, dist: 9, roll: -30, fov: 70, target: [0, 0, 0],
      shift_u: 0, shift_v: 0, near: 0.05, far: 900, w: 96, h: 96 },
];

async function sectionA() {
    const g = crumpledGrid(GRID_N);
    const input = buildInput(g.nverts, g.pos, g.idx, gridCams,
                             { dump: true, checkFrame: true });
    const w = await runWasm(input);
    const j = runJsBackend(input);

    check(w.hashes.size === gridCams.length * 2,
          `A: probe answered for all ${gridCams.length} cameras`);

    let nonEmpty = true, degenerate = true, agree = true;
    for (let i = 0; i < gridCams.length; i++) {
        const c = w.hashes.get(`cam${i}`), f = w.hashes.get(`frm${i}`);
        if (!c || !f || c.covered < 200) nonEmpty = false;
        if (!c || !f || c.hi !== f.hi || c.lo !== f.lo ||
            c.covered !== f.covered) degenerate = false;
        const jc = j.hashes.get(`cam${i}`);
        if (!jc || jc.hi !== c.hi || jc.lo !== c.lo ||
            j.masks.get(`cam${i}`) !== w.masks.get(`cam${i}`) ||
            j.streams.get(`dep${i}`) !== w.streams.get(`dep${i}`) ||
            j.streams.get(`bar${i}`) !== w.streams.get(`bar${i}`)) agree = false;
    }
    check(nonEmpty, 'A: every camera sees the mesh (>200 pixels covered)');

    let golden = true;
    for (let i = 0; i < GRID_GOLDEN.length; i++) {
        const c = w.hashes.get(`cam${i}`), want = GRID_GOLDEN[i];
        if (!c || c.hi !== want[0] || c.lo !== want[1] ||
            c.covered !== want[2]) {
            golden = false;
            console.log(`     camera ${i}: fnv ${c && c.hi} ${c && c.lo} `
                        + `covering ${c && c.covered}, expected `
                        + `${want[0]} ${want[1]} covering ${want[2]}`);
        }
    }
    check(golden,
          'A: the masks match the reference implementation\'s recorded '
          + 'answers (4 cameras)');
    check(degenerate,
          'A: render-mask! and render-frame! agree byte for byte '
          + '(4 cameras, two independent fills)');
    check(agree,
          'A: the Wasm backend and the JS backend agree byte for byte, '
          + 'masks and visibility buffers alike');
}

// ================================================== B. the Python oracle

// An explicitly set GOETEIA_RASTERLIB is the only candidate: pointing it
// somewhere wrong must say so, not quietly fall back to a copy found
// elsewhere and report on that one instead.
function findReference() {
    const candidates = process.env.GOETEIA_RASTERLIB
        ? [process.env.GOETEIA_RASTERLIB]
        : [path.resolve(REPO, '..', '10', 'rasterlib.py'),
           path.resolve(REPO, '..', '..', '10', 'rasterlib.py')];
    for (const c of candidates)
        if (fs.existsSync(c)) return path.dirname(path.resolve(c));
    return null;
}

const ORACLE = String.raw`
import json, os, struct, sys, time
sys.path.insert(0, sys.argv[1])
import rasterlib as R

REF = sys.argv[1]
out_bin = sys.argv[2]
mode = sys.argv[3]

def fnv(data):
    h = 2166136261
    for b in data:
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return (h >> 16, h & 0xFFFF)

mesh = R.Mesh3D.from_glb(os.path.join(REF, 'elf.glb'))
truth = json.load(open(os.path.join(REF, 'fitcheck-fixtures',
                                    'pose-truth.json')))

# hand the very same vertices and triangles to the other side: the
# mesh is dumped from this loader, so a difference in the answers
# cannot be a difference in the parsing
with open(out_bin, 'wb') as f:
    f.write(struct.pack('<ii', len(mesh.pos), len(mesh.tris) * 3))
    for p in mesh.pos:
        f.write(struct.pack('<fff', *p))
    for t in mesh.tris:
        f.write(struct.pack('<III', *t))

if mode == 'diff':
    # the same procedurally generated grid section A uses, rendered
    # here so the literals pinned in the harness are re-derived from
    # the reference implementation and cannot quietly go stale
    spec = json.load(open(sys.argv[4]))
    n = spec['n']
    gp, gi = [], []
    for j in range(n):
        for i in range(n):
            gp.append(((i * 5 - 2 * n) / 8, (j * 5 - 2 * n) / 8,
                       ((((i * 37 + j * 17) * 29) % 61) - 30) / 8))
    for j in range(n - 1):
        for i in range(n - 1):
            a = j * n + i
            gi.append((a, a + 1, a + n))
            gi.append((a + 1, a + n + 1, a + n))
    grid = R.Mesh3D(gp, [(0.0, 0.0, 1.0)] * len(gp), [(0.0, 0.0)] * len(gp), gi)
    for i, cd in enumerate(spec['cams']):
        w, h = cd['w'], cd['h']
        gc = R.Camera.from_dict(cd)
        gm = R.render_mask(grid, gc, w, h)
        hi, lo = fnv(gm)
        print('grid %d fnv %d %d covered %d' % (i, hi, lo, sum(gm)))

    # the four fixture poses, plus two derived ones the fixtures do not
    # cover: a camera *inside* the model, where triangles straddle the
    # near plane and go through the clipper, and one with both frame
    # shifts engaged, which every fixture leaves at zero
    poses = list(truth['poses'])
    inside = dict(poses[0]['camera'])
    inside['dist'] = mesh.radius * 0.3
    inside['near'] = mesh.radius * 0.02
    poses.append({'name': 'inside', 'camera': inside, 'size': [96, 96]})
    shifted = dict(poses[1]['camera'])
    shifted['shift_u'] = 8.0
    shifted['shift_v'] = -5.0
    poses.append({'name': 'shifted', 'camera': shifted, 'size': [128, 160]})
    cams = []
    for pose in poses:
        c = R.Camera.from_dict(pose['camera'])
        w, h = pose['size']
        cams.append(dict(pose['camera'], w=w, h=h, name=pose['name']))
        m = R.render_mask(mesh, c, w, h)
        i = len(cams) - 1
        hi, lo = fnv(m)
        print('cam %d fnv %d %d covered %d' % (i, hi, lo, sum(m)))
        print(''.join('1' if b else '0' for b in m))
        fr = R.render_frame(mesh, c, w, h)
        fm = fr.mask()
        hi, lo = fnv(fm)
        print('frm %d fnv %d %d covered %d' % (i, hi, lo, sum(fm)))
        dep, bar = [], []
        for k in range(w * h):
            if fr.tri[k] < 0:
                continue
            dep.append(str(int(fr.invd[k] * 16777216.0 + 0.5)))
            bar.append(str(int(fr.b0[k] * 67108864.0 + 0.5)))
            bar.append(str(int(fr.b1[k] * 67108864.0 + 0.5)))
            bar.append(str(int(fr.b2[k] * 67108864.0 + 0.5)))
        print('dep %d %s' % (i, ' '.join(dep)))
        print('bar %d %s' % (i, ' '.join(bar)))
    print('CAMS ' + json.dumps(cams))
else:
    pose = truth['poses'][0]
    c = R.Camera.from_dict(pose['camera'])
    ts = []
    for _ in range(10):
        t0 = time.perf_counter()
        R.render_mask(mesh, c, 256, 256)
        ts.append(time.perf_counter() - t0)
    ts.sort()
    print('MEDIAN %.6f' % ts[5])
    print('CAMS ' + json.dumps([dict(pose['camera'], w=256, h=256,
                                     name=pose['name'])]))
`;

function readMeshBin(file) {
    const b = fs.readFileSync(file);
    const nverts = b.readInt32LE(0), nidx = b.readInt32LE(4);
    const pos = new Float32Array(nverts * 3);
    for (let i = 0; i < nverts * 3; i++) pos[i] = b.readFloatLE(8 + i * 4);
    const idx = new Array(nidx);
    const o = 8 + nverts * 12;
    for (let i = 0; i < nidx; i++) idx[i] = b.readUInt32LE(o + i * 4);
    return { nverts, pos, idx };
}

function runOracle(ref, mode) {
    const script = path.join(TMP, 'oracle.py');
    fs.writeFileSync(script, ORACLE);
    const spec = path.join(TMP, 'grid.json');
    fs.writeFileSync(spec, JSON.stringify({ n: GRID_N, cams: gridCams }));
    const bin = path.join(TMP, `mesh-${mode}.bin`);
    const r = spawnSync('python3', [script, ref, bin, mode, spec],
                        { encoding: 'utf8', maxBuffer: 1 << 28 });
    if (r.status !== 0) throw new Error(r.stderr || 'python3 failed');
    const parsed = parseProbe(r.stdout);
    const cams = JSON.parse(/^CAMS (.*)$/m.exec(r.stdout)[1]);
    const median = /^MEDIAN ([\d.]+)$/m.exec(r.stdout);
    return { mesh: readMeshBin(bin), cams, parsed,
             median: median ? +median[1] : null };
}

async function sectionB(ref) {
    const o = runOracle(ref, 'diff');
    const cams = o.cams;

    let fresh = true;
    for (let i = 0; i < GRID_GOLDEN.length; i++) {
        const p = o.parsed.hashes.get(`grid${i}`), g = GRID_GOLDEN[i];
        if (!p || p.hi !== g[0] || p.lo !== g[1] || p.covered !== g[2]) {
            fresh = false;
            console.log(`     grid camera ${i}: reference says fnv `
                        + `${p && p.hi} ${p && p.lo} covering `
                        + `${p && p.covered}, harness has ${g[0]} ${g[1]} `
                        + `covering ${g[2]} -- update GRID_GOLDEN`);
        }
    }
    check(fresh, "B: section A's recorded answers still match the reference");

    const input = buildInput(o.mesh.nverts, o.mesh.pos, o.mesh.idx, cams,
                             { dump: true, checkFrame: true });
    const g = await runWasm(input);

    check(cams.length >= 3 && cams.some(c => c.shift_u !== 0),
          `B: ${cams.length} cameras (${cams.map(c => c.name).join(', ')})`);

    let identical = true;
    for (let i = 0; i < cams.length; i++) {
        const py = o.parsed.hashes.get(`cam${i}`);
        const gs = g.hashes.get(`cam${i}`);
        const pm = o.parsed.masks.get(`cam${i}`);
        const gm = g.masks.get(`cam${i}`);
        const same = py && gs && py.hi === gs.hi && py.lo === gs.lo &&
                     py.covered === gs.covered && pm === gm;
        if (!same) {
            identical = false;
            const w = cams[i].w, h = cams[i].h;
            let n = 0, minRow = h, maxRow = -1, minCol = w, maxCol = -1;
            for (let k = 0; k < w * h; k++)
                if ((pm || '')[k] !== (gm || '')[k]) {
                    n++;
                    const r = Math.floor(k / w), c = k % w;
                    if (r < minRow) minRow = r;
                    if (r > maxRow) maxRow = r;
                    if (c < minCol) minCol = c;
                    if (c > maxCol) maxCol = c;
                }
            console.log(`     camera ${cams[i].name} (${w}x${h}): `
                        + `${n} of ${w * h} pixels differ `
                        + `(python covers ${py && py.covered}, `
                        + `goeteia covers ${gs && gs.covered}); `
                        + `rows ${minRow}..${maxRow}, cols ${minCol}..${maxCol}`);
        }
    }
    check(identical,
          `B: ${cams.length} masks identical to rasterlib.py, byte for byte `
          + `(${o.mesh.nverts} vertices, ${o.mesh.idx.length / 3} triangles)`);

    // the mask cannot see inside a triangle; these can
    let interp = true, worstDep = 0, worstBar = 0, nDep = 0, nBar = 0;
    for (let i = 0; i < cams.length; i++) {
        const cmp = (tag) => {
            const a = (o.parsed.streams.get(`${tag}${i}`) || '').split(' ');
            const b = (g.streams.get(`${tag}${i}`) || '').split(' ');
            if (a.length !== b.length || a.length < 2) {
                console.log(`     camera ${cams[i].name}: ${tag} stream has `
                            + `${a.length} values from python and `
                            + `${b.length} from goeteia -- different pixels `
                            + `are covered, so the values cannot be paired`);
                return [-1, Math.abs(a.length - b.length)];
            }
            let worst = 0, n = 0;
            for (let k = 0; k < a.length; k++) {
                const d = Math.abs(+a[k] - +b[k]);
                if (d) { n++; if (d > worst) worst = d; }
            }
            return [worst, n];
        };
        const [wd, nd] = cmp('dep'), [wb, nb] = cmp('bar');
        worstDep = Math.max(worstDep, wd); nDep += nd;
        worstBar = Math.max(worstBar, wb); nBar += nb;
        const pf = o.parsed.hashes.get(`frm${i}`), gf = g.hashes.get(`frm${i}`);
        if (!pf || !gf || pf.hi !== gf.hi || pf.lo !== gf.lo) interp = false;
        if (wd !== 0 || wb !== 0) interp = false;
    }
    if (!interp && worstDep >= 0 && worstBar >= 0)
        console.log(`     1/depth: ${nDep} values differ, worst ${worstDep} `
                    + `units of 2^-24;  weights: ${nBar} differ, worst `
                    + `${worstBar} units of 2^-26`);
    check(interp,
          'B: the visibility buffer agrees too -- silhouettes, 1/depth to '
          + '2^-24 and every perspective-correct weight to 2^-26');
    return o;
}

// ======================================================== C. timing

async function sectionC(ref) {
    const o = runOracle(ref, 'bench');
    const cam = o.cams[0];
    const mk = (reps) => buildInput(o.mesh.nverts, o.mesh.pos, o.mesh.idx,
                                    [cam], { reps, dump: false });
    const one = mk(1), eleven = mk(11);
    const samples = [];
    for (let t = 0; t < 10; t++) {
        const a = performance.now();
        await runWasm(one);
        const b = performance.now();
        await runWasm(eleven);
        const c = performance.now();
        samples.push(((c - b) - (b - a)) / 10);
    }
    samples.sort((x, y) => x - y);
    const wasmMs = samples[5];
    const pyMs = o.median * 1000;
    console.log(`     256x256 mask, ${o.mesh.idx.length / 3} triangles: `
                + `wasm ${wasmMs.toFixed(1)} ms, python3 ${pyMs.toFixed(1)} ms `
                + `(${(pyMs / wasmMs).toFixed(2)}x)`);
    check(wasmMs > 0 && pyMs > 0, 'C: both sides timed 10 renders');
}

// ============================================================ main

const ref = findReference();
await sectionA();
if (ref) {
    await sectionB(ref);
    await sectionC(ref);
} else {
    console.log('SKIP B/C: the Python reference implementation was not found. '
        + 'rasterlib.py is not part of this repository; point '
        + 'GOETEIA_RASTERLIB at it (it also needs elf.glb and '
        + 'fitcheck-fixtures/pose-truth.json beside it, plus PIL) to run the '
        + 'cross-implementation comparison and the timing.');
}

fs.rmSync(TMP, { recursive: true, force: true });
process.exit(fail);
