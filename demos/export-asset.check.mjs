// Headless check for demos/export-asset.ss: compile the demo, run it
// against a mock browser (mock DOM + recording mock WebGL + a real
// WebAssembly.Memory), drive the sliders the way a user would, press
// Download, and read the bytes the page would have saved.
//
//   node demos/export-asset.check.mjs
//
// The whole scenario runs twice, once per optimization level: the
// page's live editor compiles demos at -O0, the standalone build at
// -O2, and an export that only survives one of them is broken.
//
// What is asserted:
//   * the page initializes -- program linked, three parts uploaded,
//     three indexed draws per frame;
//   * moving a slider REBUILDS: the next frame uploads different
//     vertex bytes, and the byte counts match 4*sides+6 vertices per
//     turned part;
//   * Download hands the Blob exactly the (base . len) range that
//     glb-write! returned, and the Blob length matches the GLB
//     container's own total-length field;
//   * the saved bytes are a glTF file the MAIN library reads back:
//     a probe compiled against ../03-goeteia runs (gfx gltf)'s
//     gltf-parse over them and reports layout, vertex count, index
//     count, colour and y extent per primitive -- all of which must
//     agree with the slider positions;
//   * two slider positions produce two different GLBs, both in the
//     counts (facets) and in placement alone (mast height), so the
//     parameters really do drive the geometry.
//
// The main repo is found at $GOETEIA_MAIN, else ../03-goeteia. It is
// required, not optional: the gltf-parse leg is the only part of this
// check that reads the file with something other than the code that
// wrote it, so skipping it would leave the export unverified.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { compileToBytes } from '../rt/compile.mjs';
import { makeJsBridge } from '../rt/jsbridge.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const MAIN = process.env.GOETEIA_MAIN || path.resolve(root, '../03-goeteia');

// ---- geometry the demo is expected to produce -----------------------
// (gfx mesh) mesh-cylinder with `s` segments: 4s+6 vertices, 12s
// indices.  Three turned parts share the facet count.

const vertsPerPart = s => 4 * s + 6;
const idxPerPart = s => 12 * s;
const vbytes = s => 24 * vertsPerPart(s);   // position+normal, float32

const PLINTH = 0.16;                        // $plinth in the demo
const COLORS = [
    [0.78, 0.62, 0.28, 1.0],                // brass base
    [0.62, 0.65, 0.72, 1.0],                // steel mast
    [0.92, 0.86, 0.62, 1.0],                // shade
];
// where each part must sit once it is placed: base on the floor, mast
// on the base, shade on the mast
const bandsFor = ({ mast, head }) => [
    [0, PLINTH],
    [PLINTH, PLINTH + mast],
    [PLINTH + mast, PLINTH + mast + 0.9 * head],
];

// ---- the mock browser ------------------------------------------------
// One fresh world per run: the demo installs a global generation
// counter and GL slot table, so two runs must not share any of it.

function makeWorld() {
    const gllog = [];
    const inputs = [];
    const buttons = [];
    const blobs = [];
    const revoked = [];
    const byId = new Map();
    let bufId = 0;
    let rafs = [];
    let now = 0;

    function makeGL() {
        const rec = {
            getExtension: () => null,
            createShader: () => ({ kind: 'shader' }),
            shaderSource() {}, compileShader() {},
            getShaderParameter: () => true, getShaderInfoLog: () => '',
            createProgram: () => ({ id: 'P' }),
            attachShader() {}, linkProgram() {},
            getProgramParameter: () => true, getProgramInfoLog: () => '',
            bindAttribLocation(p, i, n) { gllog.push({ op: 'attribLoc', i, n }); },
            getUniformLocation: (p, n) => ({ n }),
            createBuffer: () => ({ id: ++bufId }),
            createVertexArray: () => ({ id: 'V' }),
            bindVertexArray() {},
            bindBuffer(target, b) { gllog.push({ op: 'bind', target, b: b && b.id }); },
            bufferData(target, arr) {
                gllog.push({ op: 'bufferData', target, bytes: arr.byteLength });
            },
            enableVertexAttribArray() {},
            vertexAttribPointer(loc, n, ty, norm, stride, off) {
                gllog.push({ op: 'attrib', loc, n, stride, off });
            },
            vertexAttribDivisor() {},
            useProgram() {}, uniform1f() {}, uniform1i() {}, uniform2f() {},
            uniform3f() {},
            uniform4f(loc, r, g, b, a) {
                gllog.push({ op: 'uniform4f', n: loc.n, v: [r, g, b, a] });
            },
            uniformMatrix4fv() {},
            drawElements(mode, count) { gllog.push({ op: 'drawElements', count }); },
            drawArrays() {},
            clearColor() {}, clear() {}, enable() {}, disable() {},
            depthMask() {}, viewport() {},
            bindFramebuffer() {}, activeTexture() {}, bindTexture() {},
        };
        // GL enums: the replayer only ever uses them as keys, so the
        // property name itself is a perfectly distinct constant
        return new Proxy(rec, {
            get(t, p) {
                if (p in t) return t[p];
                if (typeof p === 'string' && /^[A-Z0-9_]+$/.test(p)) return p;
                return () => undefined;
            },
        });
    }

    function makeEl(tag) {
        const el = {
            tagName: tag,
            children: [],
            attrs: {},
            listeners: {},
            style: {},
            setAttribute(n, v) {
                this.attrs[n] = String(v);
                if (n === 'id') byId.set(String(v), this);
                // a canvas reflects width/height as numeric properties,
                // which is where (gfx fx) reads the drawing-buffer size
                if (n === 'width' || n === 'height') this[n] = Number(v);
            },
            removeAttribute(n) { delete this.attrs[n]; },
            appendChild(c) { this.children.push(c); c.parent = this; return c; },
            removeChild(c) {
                this.children = this.children.filter(k => k !== c);
                return c;
            },
            insertBefore(c, ref) {
                const i = this.children.indexOf(ref);
                this.children.splice(i < 0 ? this.children.length : i, 0, c);
                return c;
            },
            replaceChild(nw, old) {
                const i = this.children.indexOf(old);
                if (i < 0) this.children.push(nw); else this.children[i] = nw;
                nw.parent = this;
                return old;
            },
            addEventListener(k, f) { (this.listeners[k] ||= []).push(f); },
            click() {
                (this.listeners.click || []).forEach(f => f({ target: this }));
            },
            getContext() { return this.gl ||= makeGL(); },
        };
        if (tag === 'input') inputs.push(el);
        if (tag === 'button') buttons.push(el);
        return el;
    }

    // Blob + object URLs: the Blob copies its parts at construction,
    // the way the real one does, so what we assert on is what the
    // browser would have written to disk
    class MockBlob {
        constructor(parts, opts) {
            // record the VIEW's own base and length before copying:
            // that pair is exactly what glb-write! returned
            this.views = parts.map(v => ({ base: v.byteOffset, len: v.length }));
            this.bytes = Buffer.concat(parts.map(v => Buffer.from(v)));
            this.type = opts && opts.type;
            blobs.push(this);
        }
    }
    const objectUrls = new Map();
    let urlN = 0;
    const RealURL = globalThis.URL;
    const urlShim = new Proxy(RealURL, {
        get(t, p) {
            if (p === 'createObjectURL')
                return b => {
                    const u = `blob:mock/${++urlN}`;
                    objectUrls.set(u, b);
                    return u;
                };
            if (p === 'revokeObjectURL')
                return u => { revoked.push(u); objectUrls.delete(u); };
            return Reflect.get(t, p);
        },
    });

    const liveEl = makeEl('div');
    byId.set('live', liveEl);

    return {
        gllog, inputs, buttons, blobs, revoked, byId, liveEl,
        install() {
            globalThis.Blob = MockBlob;
            globalThis.URL = urlShim;
            globalThis.document = {
                createElement: makeEl,
                createTextNode: s => ({ tagName: '#text', text: String(s), children: [] }),
                getElementById: id => byId.get(id) || null,
                querySelector: () => null,
            };
            globalThis.requestAnimationFrame = cb => { rafs.push(cb); return rafs.length; };
        },
        pump() {
            now += 16;
            const cbs = rafs;
            rafs = [];
            cbs.forEach(cb => cb(now));
        },
    };
}

const io = {
    write_byte() {}, read_byte: () => -1, path_byte() {},
    open_read: () => -1, open_write: () => -1,
    fread: () => -1, fwrite() {}, fclose() {},
};

// the text a subtree renders to, for reading the status line back
const textOf = el => el.tagName === '#text' ? el.text
    : (el.children || []).map(textOf).join('');

// ---- the probe: the main library reads the file back ----------------

if (!fs.existsSync(path.join(MAIN, 'lib/gfx/gltf.ss'))) {
    console.error(
        `FAIL: the main Goeteia repo is not at ${MAIN}, so the saved bytes ` +
        `would never be read back by anything but the writer.\n` +
        `      Point GOETEIA_MAIN at a checkout of github.com/guenchi/Goeteia.`);
    process.exit(1);
}
const mainCompile = await import(pathToFileURL(path.join(MAIN, 'rt/compile.mjs')));
const mainRun = await import(pathToFileURL(path.join(MAIN, 'rt/run.mjs')));

// GLB bytes on stdin -> staging -> gltf-parse -> one line per
// primitive, "layout|vcount|icount|r,g,b,a|ymin,ymax".  The y range is
// what proves the parts were PLACED: counts, colours and file size are
// identical whether the lamp is stacked or every part sits at the
// origin.
const PROBE = `
(import (rnrs) (web js) (gfx gl) (gfx glsl) (gfx fx) (gfx mat)
        (gfx mesh) (gfx gltf))
(js-eval "globalThis.__probecanvas = { width:8, height:8, addEventListener(){}, getContext(){ return new Proxy({}, { get:(t,p)=> /^[A-Z0-9_]+$/.test(p) ? p : /Parameter$/.test(p) ? (()=>true) : (()=>({})) }) } }")
(fx-init! (js-get (js-global) "__probecanvas"))
(define buf (fx-alloc! 4194304))
(define n
  (let loop ((k 0))
    (let ((b (%read-byte)))
      (if (< b 0)
          k
          (begin (%mem-u8-set! (+ buf k) b) (loop (+ k 1)))))))
(define g (gltf-parse buf n))
(define (yrange p)
  (let* ((vb (gprim-vbase p))
         (st (gprim-stride p))
         (n (quotient (gprim-vbytes p) st))
         (y0 (%mem-f32-ref (+ vb 4))))
    (let loop ((i 1) (lo y0) (hi y0))
      (if (= i n)
          (cons lo hi)
          (let ((y (%mem-f32-ref (+ vb (* i st) 4))))
            (loop (+ i 1)
                  (if (fl<? y lo) y lo)
                  (if (fl<? hi y) y hi)))))))
(display "bytes ") (display n) (newline)
(for-each
 (lambda (p)
   (display (gprim-layout p)) (display "|")
   (display (quotient (gprim-vbytes p) (gprim-stride p))) (display "|")
   (display (gprim-icount p)) (display "|")
   (let ((c (gprim-color p)))
     (display (vector-ref c 0)) (display ",")
     (display (vector-ref c 1)) (display ",")
     (display (vector-ref c 2)) (display ",")
     (display (vector-ref c 3)))
   (display "|")
   (let ((r (yrange p)))
     (display (car r)) (display ",") (display (cdr r)))
   (newline))
 (gltf-prims g))
`;
const probeWasm = await mainCompile.compileSource(PROBE, { baseDir: MAIN });

async function parseGlb(bytes) {
    const { text } = await mainRun.runModule(probeWasm, bytes);
    const lines = text.trim().split('\n');
    const n = Number(lines[0].split(' ')[1]);
    const prims = lines.slice(1).map(l => {
        const [layout, vcount, icount, color, ys] = l.split('|');
        const [ymin, ymax] = ys.split(',').map(Number);
        return {
            layout, vcount: Number(vcount), icount: Number(icount),
            color: color.split(',').map(Number), ymin, ymax,
        };
    });
    return { n, prims };
}

// ---- one full run of the demo ---------------------------------------

const SIDES0 = 8;                      // the demo's initial facet count
const SIDES1 = 16;

async function run(label, opts) {
    const w = makeWorld();
    w.install();

    const wasm = await compileToBytes(path.join(root, 'demos/export-asset.ss'), opts);
    let ex;
    const { instance } = await WebAssembly.instantiate(
        wasm, { io, js: makeJsBridge(() => ex) });
    ex = instance.exports;
    globalThis.__goeteia_mem = ex.memory;
    ex.main();

    // (1) the page came up
    assert.equal(w.inputs.length, 4, `${label}: four sliders, got ${w.inputs.length}`);
    assert.equal(w.buttons.length, 1, `${label}: one download button`);
    assert.ok(w.byId.has('c'), `${label}: the canvas mounted with id="c"`);

    w.pump();                          // one frame

    const uploads = () => w.gllog
        .filter(e => e.op === 'bufferData' && e.target === 'ARRAY_BUFFER')
        .map(e => e.bytes);
    const draws = () => w.gllog
        .filter(e => e.op === 'drawElements').map(e => e.count);
    const statusText = () => textOf(w.liveEl);

    assert.deepEqual(uploads(), [vbytes(SIDES0), vbytes(SIDES0), vbytes(SIDES0)],
        `${label}: three parts upload ${vbytes(SIDES0)} vertex bytes each, ` +
        `got [${uploads()}]`);
    assert.deepEqual(draws(),
        [idxPerPart(SIDES0), idxPerPart(SIDES0), idxPerPart(SIDES0)],
        `${label}: three indexed draws of ${idxPerPart(SIDES0)} indices, ` +
        `got [${draws()}]`);
    // the attribute setup really is the 24-byte position+normal interleave
    const attribs = w.gllog.filter(e => e.op === 'attrib');
    assert.ok(attribs.length >= 2 && attribs.every(a => a.stride === 24),
        `${label}: attributes stride 24, got ${JSON.stringify(attribs)}`);
    assert.match(statusText(), new RegExp(`${3 * vertsPerPart(SIDES0)} verts`),
        `${label}: the status line reports the vertex count: ${statusText()}`);

    // (2) download at the initial parameters
    const download = () => {
        const before = w.blobs.length;
        w.buttons[0].click();
        assert.equal(w.blobs.length, before + 1,
            `${label}: the click produced one Blob`);
        return w.blobs[w.blobs.length - 1];
    };
    const totalOf = b => b.bytes.readUInt32LE(8);   // GLB header, total length

    const blobA = download();
    assert.equal(blobA.type, 'model/gltf-binary',
        `${label}: the Blob carries the glTF mime`);
    assert.equal(blobA.views.length, 1, `${label}: one view goes into the Blob`);
    assert.equal(blobA.bytes.readUInt32LE(0), 0x46546C67, `${label}: magic "glTF"`);
    assert.equal(blobA.views[0].len, blobA.bytes.length,
        `${label}: Blob length == view length`);
    // the container's own total-length field must equal what we sent:
    // a wrong length -- or a stale base -- shows up right here
    assert.equal(totalOf(blobA), blobA.bytes.length,
        `${label}: the GLB header's total length (${totalOf(blobA)}) must equal ` +
        `the bytes handed to the Blob (${blobA.bytes.length})`);

    // the object URL is revoked, but only after the click was queued
    await new Promise(r => setTimeout(r, 5));
    assert.equal(w.revoked.length, 1,
        `${label}: the object URL is revoked on the next turn`);

    // (3) a slider rebuilds
    w.gllog.length = 0;
    const facets = w.inputs[3];        // base, mast, head, facets
    facets.listeners.input.forEach(f => f({ target: { value: String(SIDES1) } }));
    w.pump();

    assert.deepEqual(uploads(), [vbytes(SIDES1), vbytes(SIDES1), vbytes(SIDES1)],
        `${label}: after the slider the parts upload ${vbytes(SIDES1)} bytes ` +
        `each, got [${uploads()}] -- a preview that did not rebuild uploads ` +
        `nothing at all (its ${vbytes(SIDES0)}-byte buffers are already on the GPU)`);
    assert.deepEqual(draws(),
        [idxPerPart(SIDES1), idxPerPart(SIDES1), idxPerPart(SIDES1)],
        `${label}: the draws follow the new index counts, got [${draws()}]`);
    assert.match(statusText(), new RegExp(`${3 * vertsPerPart(SIDES1)} verts`),
        `${label}: the status line follows the slider: ${statusText()}`);

    // (4) the second download is the NEW geometry
    const blobB = download();
    assert.notEqual(blobB.views[0].base, blobA.views[0].base,
        `${label}: the second export comes from a freshly written range, ` +
        `not the old base`);
    assert.equal(totalOf(blobB), blobB.bytes.length,
        `${label}: the second GLB header agrees with its byte count`);
    assert.ok(blobB.bytes.length > blobA.bytes.length,
        `${label}: more facets must mean a bigger file: ` +
        `${blobA.bytes.length} -> ${blobB.bytes.length}`);

    // (5) a parameter that does NOT change any count: mast height moves
    // geometry only in placement, so only the y extents can see it
    w.inputs[1].listeners.input.forEach(f => f({ target: { value: '120' } }));
    w.pump();
    const blobC = download();

    return { label, blobA, blobB, blobC };
}

// ---- read every export back with the main library --------------------

async function checkGlb(blob, params, tag) {
    const { sides } = params;
    const { n, prims } = await parseGlb(blob.bytes);
    const bands = bandsFor(params);
    assert.equal(n, blob.bytes.length, `${tag}: the probe read every byte`);
    assert.equal(prims.length, 3, `${tag}: three primitives, got ${prims.length}`);
    prims.forEach((p, i) => {
        assert.equal(p.layout, '(position normal)',
            `${tag}: primitive ${i} layout, got ${p.layout}`);
        assert.equal(p.vcount, vertsPerPart(sides),
            `${tag}: primitive ${i} has ${p.vcount} vertices, ` +
            `expected ${vertsPerPart(sides)} for ${sides} facets`);
        assert.equal(p.icount, idxPerPart(sides),
            `${tag}: primitive ${i} has ${p.icount} indices, ` +
            `expected ${idxPerPart(sides)}`);
        p.color.forEach((c, k) => assert.ok(Math.abs(c - COLORS[i][k]) < 1e-5,
            `${tag}: primitive ${i} colour ${k} = ${c}, want ${COLORS[i][k]}`));
        assert.ok(Math.abs(p.ymin - bands[i][0]) < 2e-3
                  && Math.abs(p.ymax - bands[i][1]) < 2e-3,
            `${tag}: primitive ${i} spans y ${p.ymin}..${p.ymax}, ` +
            `expected ${bands[i][0]}..${bands[i][1]}`);
    });
    return prims;
}

const A = { sides: SIDES0, mast: 3.0, head: 0.45 };   // the demo's defaults
const B = { sides: SIDES1, mast: 3.0, head: 0.45 };
const C = { sides: SIDES1, mast: 1.2, head: 0.45 };

for (const opts of [{}, { script: true }]) {
    const label = opts.script ? '-O0 (live editor)' : '-O2 (build)';
    const { blobA, blobB, blobC } = await run(label, opts);
    const pa = await checkGlb(blobA, A, `${label} A (8 facets)`);
    const pb = await checkGlb(blobB, B, `${label} B (16 facets)`);
    const pc = await checkGlb(blobC, C, `${label} C (shorter mast)`);
    assert.notEqual(pa[0].vcount, pb[0].vcount,
        `${label}: the facet slider must change the vertex count`);
    assert.equal(pc[0].vcount, pb[0].vcount,
        `${label}: the mast slider must NOT change the vertex count`);
    assert.ok(pc[2].ymax < pb[2].ymax - 1.0,
        `${label}: the shorter mast must lower the shade: ` +
        `${pb[2].ymax} -> ${pc[2].ymax}`);
    console.log(
        `ok   ${label}: sliders rebuild; the downloaded bytes read back ` +
        `through (gfx gltf) as 3 placed primitives ` +
        `(${pa[0].vcount} -> ${pb[0].vcount} verts per part, ` +
        `top ${pb[2].ymax.toFixed(3)} -> ${pc[2].ymax.toFixed(3)})`);
}
console.log('PASS: export-asset.ss');
