// G05 (2026-09-06 review, still live 2026-09-09): the WebGPU vertex
// attribute parser computes a NaN offset for every attribute after a
// scalar one.
//
// RED ON PURPOSE.  `off += Number(f.replace(/.*x/, '')) * 4` takes the
// digits after an `x` -- `float32x2` gives 2 -- but a scalar format has
// no `x`, so the replace returns the whole word and Number('float32')
// is NaN.  From then on every offset is NaN, and a NaN offset in a
// vertex buffer layout is not a diagnostic anywhere: the pipeline is
// built, the draw is issued, and the attributes read from nowhere.
//
// ⚠️ The parser is JavaScript embedded in lib/gfx/gpu.ss as a list of
// string literals, and there is no WebGPU in this process to run it
// through.  So the method's own text is lifted out and called
// directly.  That is brittle on purpose: if the method is renamed or
// reshaped this cell fails to find it and SAYS SO, rather than quietly
// testing nothing -- which is the failure mode that matters for a
// harness that reaches into another file's source.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const src = fs.readFileSync(path.join(root, 'lib', 'gfx', 'gpu.ss'), 'utf8');

// Each JS line is one Scheme string literal; take the run of them from
// `parseAttrs(` to the line that closes the method.
const lines = src.split('\n');
const start = lines.findIndex(l => /^\s*"\s*parseAttrs\(/.test(l));
assert.ok(start >= 0, 'parseAttrs is no longer a line of its own in lib/gfx/gpu.ss; '
                    + 'this cell can no longer find what it judges');
const body = [];
for (let i = start; i < lines.length; i++) {
    const m = lines[i].match(/^\s*"(.*)"\s*$/);
    assert.ok(m, `line ${i + 1} of lib/gfx/gpu.ss is not a plain string literal, `
               + 'so the method text cannot be lifted out: ' + lines[i]);
    body.push(m[1].replace(/\\"/g, '"'));
    if (/^\s*return attrs;/.test(m[1])) break;
    assert.ok(i - start < 30, 'parseAttrs did not end within thirty lines');
}
const text = body.join('\n').replace(/,\s*$/, '');
const parseAttrs = new Function(`const o = { ${text} }; return o.parseAttrs;`)();

const offsets = (fmts) => parseAttrs(fmts, 0).map(a => a.offset);

// The line the review names: a scalar followed by anything.
assert.deepEqual(offsets('float32,float32x2'), [0, 4],
                 'a scalar format must advance the offset by four bytes');
// and the shapes either side of it, so a repair that special-cased
// `float32` alone would not pass
assert.deepEqual(offsets('float32x2,float32x2'), [0, 8], 'x2 is eight bytes');
assert.deepEqual(offsets('float32x3,float32'), [0, 12], 'x3 is twelve bytes');
assert.deepEqual(offsets('float32,float32,float32'), [0, 4, 8],
                 'three scalars in a row');
assert.deepEqual(offsets('float32x4,float32x2,float32'), [0, 16, 24],
                 'a mixed run, which is what a real vertex layout looks like');
// shaderLocation must still count up regardless
assert.deepEqual(parseAttrs('float32,float32x2', 0).map(a => a.shaderLocation), [0, 1],
                 'locations are consecutive from the base');
assert.deepEqual(parseAttrs('float32x2', 3).map(a => a.shaderLocation), [3],
                 'and start at the base they were given');
// ⛔ An offset that is not a number must never be produced.  Written
// separately from the equality checks above because NaN !== NaN makes
// deepEqual on an array of numbers awkward to reason about, and this is
// the property the defect actually violates.
for (const f of ['float32', 'float32x2,float32,float32x2', 'uint32,sint32']) {
    for (const o of offsets(f))
        assert.ok(Number.isFinite(o), `offset ${o} for "${f}" is not a finite number`);
}
console.log('gfx-gpu-attrs: ok');
