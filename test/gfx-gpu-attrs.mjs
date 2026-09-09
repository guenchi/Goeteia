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

// ---- every width, not just the 32-bit ones ----
//
// ⭐ The original `* 4` assumed four bytes per component, so it was
// wrong for EVERY format that is not 32-bit -- `float16x2` came out 8
// bytes instead of 4, `uint8x4` came out 16 instead of 4.  That half
// was invisible because everything in this tree today uses float32*,
// and the cells above are all float32 too: they would have passed a
// repair that fixed the scalar case and kept the four.
//
// ⚠️ These are here rather than left in the repair's own probe on
// purpose.  A fix verified only by the assertions its author wrote is
// verified by someone who already knows what they built; the suite has
// to carry the dimension independently, or the coverage disappears when
// that probe does.
for (const [fmts, want] of [
    ['float16x2,float32', [0, 4]],
    ['float16x4,float32', [0, 8]],
    ['uint8x2,float32', [0, 2]],
    ['uint8x4,float32', [0, 4]],
    ['unorm8x4,float32', [0, 4]],
    ['snorm16x2,float32', [0, 4]],
    ['uint16x4,float32', [0, 8]],
    ['sint32x3,float32', [0, 12]],
    // a run that changes width three times, which is what a packed
    // vertex actually looks like
    ['unorm8x4,float16x2,float32x3,uint16x2', [0, 4, 8, 20]],
]) {
    assert.deepEqual(offsets(fmts), want, `offsets for "${fmts}"`);
}

// ---- the whole legal set, enumerated ----
//
// ⭐ The implementation DERIVES sizes from the format's structure; this
// list is copied from the specification.  Two different routes to the
// same thirty answers, which is the point: a rule with a mistake in it
// and a table with a mistake in it are unlikely to have the same
// mistake, and neither is checking itself.
//
// ⛔ The list must not be generated from the same rule the code uses.
// It would then agree by construction and say nothing.
const LEGAL = {
    'uint8x2': 2, 'uint8x4': 4, 'uint16x2': 4, 'uint16x4': 8,
    'uint32': 4, 'uint32x2': 8, 'uint32x3': 12, 'uint32x4': 16,
    'sint8x2': 2, 'sint8x4': 4, 'sint16x2': 4, 'sint16x4': 8,
    'sint32': 4, 'sint32x2': 8, 'sint32x3': 12, 'sint32x4': 16,
    'unorm8x2': 2, 'unorm8x4': 4, 'unorm16x2': 4, 'unorm16x4': 8,
    'snorm8x2': 2, 'snorm8x4': 4, 'snorm16x2': 4, 'snorm16x4': 8,
    'float16x2': 4, 'float16x4': 8,
    'float32': 4, 'float32x2': 8, 'float32x3': 12, 'float32x4': 16,
};
assert.equal(Object.keys(LEGAL).length, 30, 'the enumerated set is the thirty of the spec');
for (const [fmt, size] of Object.entries(LEGAL)) {
    assert.deepEqual(offsets(`${fmt},${fmt}`), [0, size],
                     `"${fmt}" must advance the offset by ${size}`);
}

// ---- what must be refused, by name ----
//
// ⛔ Not silently treated as zero.  A layout whose offsets are all zero
// and one whose offsets are NaN both put nothing recognisable on the
// screen, and the first is harder to find, because zero looks like a
// number somebody meant.
const refused = (fmt) => {
    try { parseAttrs(fmt, 0); return null; }
    catch (e) { return String(e.message || e); }
};
for (const bad of [
    'float64',        // not a vertex format at all
    'float32x5',      // no such component count
    'wobble',         // not a format
    'uint8',          // 8-bit exists only as x2 and x4
    'float16',        // likewise 16-bit
    'float8x2',       // there is no 8-bit float
    'unorm32x2',      // normalized formats are 8- and 16-bit only
    'unorm10-10-10-2',// real, and deliberately out of scope
    '',               // the empty string is not a format
]) {
    const msg = refused(bad);
    assert.ok(msg, `"${bad}" was accepted`);
    assert.ok(msg.includes(bad) || bad === '',
              `the refusal of "${bad}" does not name it: ${msg}`);
}
console.log('gfx-gpu-attrs: ok');
