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

// The writer against a real exporter's file: test/assets/p1.glb goes
// through the reader and straight back out through the writer, and
// the RESULT is judged by tools that never ran either:
//   * archive-born glbcheck.py (stdlib Python): container, chunk
//     alignment, every bufferView and accessor in bounds, every index
//     reference in range, PNG magic under every image;
//   * a normalized comparison of the JSON the exporter wrote and the
//     JSON the writer wrote -- samplers, texture (source, sampler)
//     pairs, every material slot's index/texCoord/scale/strength and
//     factors, morph target attribute names, camera parameters;
//   * Blender, headless, re-importing both files and counting meshes,
//     armatures, materials, images, shape keys, actions and cameras --
//     skipped with the reason when /Applications/Blender.app is absent.
//
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-glb-p1-'));
const original = path.join(root, 'test', 'assets', 'p1.glb');
const reexport = path.join(dir, 'p1-re.glb');
const checker = path.join(root, 'test', 'glbcheck.py');
const BLENDER = '/Applications/Blender.app/Contents/MacOS/Blender';

let failed = false;
function require_(cond, message, detail) {
    if (cond) return;
    failed = true;
    console.error(`glb-p1: ${message}`);
    if (detail !== undefined) console.error(detail);
}

// ---- re-export through the probe ----
const src = path.join(root, 'test', 'probes', 'glb-p1.ss');
const wasm = path.join(dir, 'probe.wasm');
try {
    execFileSync(path.join(root, 'bin/goeteiac'), [src, wasm], { cwd: root, stdio: 'pipe' });
} catch (e) {
    require_(false, 'the probe compiles', String(e.stderr || e.stdout || e));
    process.exit(1);
}
const r = spawnSync(process.execPath, [path.join(root, 'rt', 'run.mjs'), wasm, '--', reexport], { cwd: root, encoding: 'utf8' });
require_(r.status === 0 && fs.existsSync(reexport), 'the probe re-exports the file', `${r.stdout}\n${r.stderr}`);
if (!fs.existsSync(reexport)) process.exit(1);

// ---- structural check by an independent parser ----
const chk = spawnSync('python3', [checker, reexport], { encoding: 'utf8' });
require_(chk.status === 0, 'the re-export passes the structural checker', chk.stdout + chk.stderr);
// And nothing in it went unchecked.  The checker declines parts it
// cannot read -- a compressed bufferView, say -- and reports them
// without failing, which is right for a file that is allowed to have
// them.  A re-export produced by this probe is not: if its interesting
// parts ever start being declined, the exit status alone would keep
// saying yes about a file nobody looked at.
try {
    const j = JSON.parse(chk.stdout || '{}');
    require_(!(j.not_checked || []).length,
             'the checker actually checked the re-export, rather than declining parts of it',
             (j.not_checked || []).join('\n'));
} catch (e) {
    require_(false, 'the checker printed readable JSON', String(e));
}

// ---- normalized JSON comparison ----
function jsonOf(file) {
    const b = fs.readFileSync(file);
    return JSON.parse(b.subarray(20, 20 + b.readUInt32LE(12)).toString('utf8'));
}
const a = jsonOf(original), b = jsonOf(reexport);
const norm = x => JSON.stringify(x);
const num = x => (typeof x === 'number' ? Number(x.toFixed(6)) : x);
const sampler = s => ({ mag: s.magFilter, min: s.minFilter, wS: s.wrapS ?? 10497, wT: s.wrapT ?? 10497 });
// each slot keeps ITS scalar key: scale on the normal map, strength on
// occlusion, neither elsewhere -- a writer that swapped the keys would
// read as equal under a merged view
const texref = (t, key) => t && { index: t.index, texCoord: t.texCoord ?? 0,
                                  scalar: key ? num(t[key] ?? 1) : 1,
                                  stray: ['scale', 'strength'].filter(k => k !== key && k in t) };
const material = m => ({
    color: (m.pbrMetallicRoughness?.baseColorFactor ?? [1, 1, 1, 1]).map(num),
    metallic: num(m.pbrMetallicRoughness?.metallicFactor ?? 1),
    roughness: num(m.pbrMetallicRoughness?.roughnessFactor ?? 1),
    emissive: (m.emissiveFactor ?? [0, 0, 0]).map(num),
    base: texref(m.pbrMetallicRoughness?.baseColorTexture, null),
    mr: texref(m.pbrMetallicRoughness?.metallicRoughnessTexture, null),
    normal: texref(m.normalTexture, 'scale'), emissive_t: texref(m.emissiveTexture, null), occlusion: texref(m.occlusionTexture, 'strength'),
});
// materials are compared per PRIMITIVE, in scene walk order: the
// reader keeps material data on the primitive, so the re-export has
// one material per primitive and identity is not what is asserted
function primsOf(j) {
    const out = [];
    const walk = ni => { const n = j.nodes[ni]; if (n.mesh !== undefined) for (const p of j.meshes[n.mesh].primitives) out.push({ p, n }); for (const c of n.children ?? []) walk(c); };
    for (const rt of j.scenes[j.scene ?? 0].nodes) walk(rt);
    return out;
}
const pa = primsOf(a), pb = primsOf(b);
require_(pa.length === pb.length, 'same number of primitives in walk order', `${pa.length} vs ${pb.length}`);
require_(norm(a.samplers.map(sampler)) === norm(b.samplers.map(sampler)), 'samplers agree', `${norm(a.samplers)}\n${norm(b.samplers)}`);
require_(norm(a.textures.map(t => [t.source, t.sampler ?? null])) === norm(b.textures.map(t => [t.source, t.sampler ?? null])), 'texture (source, sampler) pairs agree');
require_(a.images.length === b.images.length, 'image count agrees');
pa.forEach(({ p, n }, i) => {
    const q = pb[i];
    if (!q) return;
    require_(norm(material(a.materials[p.material])) === norm(material(b.materials[q.p.material])),
             `primitive ${i}: every material slot agrees`,
             `${norm(material(a.materials[p.material]))}\n${norm(material(b.materials[q.p.material]))}`);
    const names = t => Object.keys(t).sort().join(',');
    require_(norm((p.targets ?? []).map(names)) === norm((q.p.targets ?? []).map(names)), `primitive ${i}: morph target attribute sets agree`);
    require_((n.skin === undefined) === (q.n.skin === undefined), `primitive ${i}: skinned on both sides or neither`);
});
// accessor payloads, decoded here (float32 only, which is all p1 has)
function floats(j, file, ai) {
    const buf = fs.readFileSync(file); const jl = buf.readUInt32LE(12); const bin = buf.subarray(28 + jl);
    const acc = j.accessors[ai]; const bv = j.bufferViews[acc.bufferView];
    const n = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT4: 16 }[acc.type];
    const stride = bv.byteStride ?? 4 * n; const off = (bv.byteOffset ?? 0) + (acc.byteOffset ?? 0);
    const out = [];
    for (let i = 0; i < acc.count; i++) for (let k = 0; k < n; k++) out.push(num(bin.readFloatLE(off + i * stride + 4 * k)));
    return out;
}
// skins: joint lists and inverse-bind values
require_(a.skins.length === b.skins.length, 'skin count agrees');
a.skins.forEach((sa, i) => {
    const sb = b.skins[i]; if (!sb) return;
    require_(norm(sa.joints) === norm(sb.joints), `skin ${i}: joint node lists agree`);
    const ia = sa.inverseBindMatrices === undefined ? null : floats(a, original, sa.inverseBindMatrices);
    const ib = sb.inverseBindMatrices === undefined ? null : floats(b, reexport, sb.inverseBindMatrices);
    require_(norm(ia) === norm(ib), `skin ${i}: inverse bind matrices agree`);
});
// the primitive's skin binding, not only its presence
pa.forEach(({ n }, i) => { const q = pb[i]; if (q) require_(n.skin === q.n.skin, `primitive ${i}: bound to the same skin index`); });
// mesh weights
pa.forEach(({ p, n }, i) => {
    const q = pb[i]; if (!q) return;
    const wa = a.meshes[n.mesh].weights ?? [], wb = b.meshes[q.n.mesh].weights ?? [];
    require_(norm(wa.map(num)) === norm(wb.map(num)), `primitive ${i}: mesh weights agree`);
});
// animations: every channel (node, path, interpolation) and every sampler's key count
require_(a.animations.length === b.animations.length, 'animation count agrees');
a.animations.forEach((ca, i) => {
    const cb = b.animations[i]; if (!cb) return;
    const shape = (doc, c) => c.channels.map(ch => [ch.target.node, ch.target.path, c.samplers[ch.sampler].interpolation ?? 'LINEAR',
                                                     doc.accessors[c.samplers[ch.sampler].input].count,
                                                     doc.accessors[c.samplers[ch.sampler].output].count]);
    require_(norm(shape(a, ca)) === norm(shape(b, cb)), `animation ${i}: channels agree`, `${norm(shape(a, ca))}\n${norm(shape(b, cb))}`);
});
const cam = c => ({ type: c.type, ...(c.perspective ? { yfov: num(c.perspective.yfov), znear: num(c.perspective.znear), zfar: num(c.perspective.zfar), aspect: num(c.perspective.aspectRatio) } : { xmag: num(c.orthographic.xmag), ymag: num(c.orthographic.ymag), znear: num(c.orthographic.znear), zfar: num(c.orthographic.zfar) }) });
require_(norm((a.cameras ?? []).map(cam)) === norm((b.cameras ?? []).map(cam)), 'cameras agree', `${norm(a.cameras)}\n${norm(b.cameras)}`);
require_(norm(a.nodes.map(n => n.camera ?? null)) === norm(b.nodes.map(n => n.camera ?? null)), 'camera bindings agree node for node');
// the image bytes themselves
function imageBytes(j, file) {
    const buf = fs.readFileSync(file); const jl = buf.readUInt32LE(12); const bin = buf.subarray(28 + jl);
    return j.images.map(im => { const bv = j.bufferViews[im.bufferView]; return bin.subarray(bv.byteOffset ?? 0, (bv.byteOffset ?? 0) + bv.byteLength).toString('hex'); });
}
require_(norm(imageBytes(a, original)) === norm(imageBytes(b, reexport)), 'every embedded image is byte-identical');

// ---- Blender re-import, when Blender is here ----
if (fs.existsSync(BLENDER)) {
    const script = path.join(dir, 'reimport.py');
    fs.writeFileSync(script, `
import bpy, sys, json
f = sys.argv[sys.argv.index('--')+1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=f)
meshes=[o for o in bpy.data.objects if o.type=='MESH']
print('REIMPORT ' + json.dumps({'meshes': len(meshes), 'armatures': len([o for o in bpy.data.objects if o.type=='ARMATURE']),
  'cameras': len([o for o in bpy.data.objects if o.type=='CAMERA']), 'materials': len(bpy.data.materials), 'images': len(bpy.data.images),
  'shapekeys': sorted([len(o.data.shape_keys.key_blocks)-1 if o.data.shape_keys else 0 for o in meshes]), 'actions': len(bpy.data.actions)}))
`);
    const counts = file => {
        const o = spawnSync(BLENDER, ['-b', '--python', script, '--', file], { encoding: 'utf8' });
        const line = (o.stdout + o.stderr).split('\n').find(l => l.startsWith('REIMPORT '));
        require_(o.status === 0 && line, `Blender imports ${path.basename(file)} and reports`, (o.stdout + o.stderr).slice(-400));
        return line ? line.slice(9) : null;
    };
    const ca = counts(original), cb = counts(reexport);
    require_(ca !== null && ca === cb, 'Blender re-imports the same counts from both files', `original: ${ca}\nre-export: ${cb}`);
} else {
    console.log('glb-p1: NOT EXERCISED HERE (Blender re-import needs /Applications/Blender.app; install Blender 4.x to run it)');
}

if (!failed) console.log('glb-p1: ok');
process.exit(failed ? 1 : 0);
