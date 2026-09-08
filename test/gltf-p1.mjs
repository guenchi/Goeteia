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

// The reader against a real exporter's file: test/assets/p1.glb is a
// Blender 4.5 export (plus a second sampler and an occlusion strength
// patched into its JSON) carrying embedded textures on every material
// slot, two samplers, a second UV set, morph targets with normals,
// two skins, a camera and four clips.  test/probes/gltf-p1.ss prints
// what the reader saw; the expectation is derived here from a parse
// of the same file's JSON chunk that never runs the reader.  The
// material, sampler, texture and camera VALUES are the exporter's own
// numbers read straight from the JSON; the layout line mirrors the
// reader's documented interleave rules (walk order, uv padding), so
// for that line this is a contract check, not independent evidence.
//
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-p1-'));
const glb = path.join(root, 'test', 'assets', 'p1.glb');

let failed = false;
function require_(cond, message, detail) {
    if (cond) return;
    failed = true;
    console.error(`gltf-p1: ${message}`);
    if (detail !== undefined) console.error(detail);
}

// ---- the independent parse ----
const bytes = fs.readFileSync(glb);
const jlen = bytes.readUInt32LE(12);
const j = JSON.parse(bytes.subarray(20, 20 + jlen).toString('utf8'));
const scene = j.scenes[j.scene ?? 0];
const prims = [];            // in the reader's walk order: scene roots, depth first
function walk(ni) {
    const n = j.nodes[ni];
    if (n.mesh !== undefined)
        for (const p of j.meshes[n.mesh].primitives) prims.push({ p, node: ni, skin: n.skin });
    for (const c of n.children ?? []) walk(c);
}
for (const r of scene.nodes) walk(r);
const num = x => { const v = Number(x) * 1e6; return String(Math.sign(v) * Math.round(Math.abs(v))); };   // millionths, half away from zero, as the probe prints
function ref(t, uvDefault) {
    if (!t) return '-';
    const tex = j.textures[t.index];
    return `${t.index}/${tex.source}/${tex.sampler ?? '#f'}/${t.texCoord ?? 0}/${num(t.scale ?? t.strength ?? 1)}`;
}
const expected = [
    `images ${(j.images ?? []).length}`,
    `textures ${(j.textures ?? []).length}`,
    `samplers ${(j.samplers ?? []).length}`,
    `skins ${(j.skins ?? []).length}`,
    `anims ${(j.animations ?? []).length}`,
    `cameras ${(j.cameras ?? []).length}`,
    `prims ${prims.length}`,
];
prims.forEach(({ p, skin }, i) => {
    const m = p.material !== undefined ? j.materials[p.material] : {};
    const pbr = m.pbrMetallicRoughness ?? {};
    expected.push(`prim ${i} base=${ref(pbr.baseColorTexture)} mr=${ref(pbr.metallicRoughnessTexture)}` +
                  ` normal=${ref(m.normalTexture)} emissive=${ref(m.emissiveTexture)} occlusion=${ref(m.occlusionTexture)}`);
    const attrs = p.attributes;
    const layout = ['position', 'normal'];
    const past = ['TANGENT', 'COLOR_0', 'JOINTS_0', 'WEIGHTS_0', 'TEXCOORD_1'].some(k => k in attrs) || 'TEXCOORD_0' in attrs;
    if (past) layout.push('uv');
    if ('TANGENT' in attrs) layout.push('tangent');
    if ('COLOR_0' in attrs) layout.push('color');
    if ('JOINTS_0' in attrs && 'WEIGHTS_0' in attrs) layout.push('joints', 'weights');
    if ('TEXCOORD_1' in attrs) layout.push('uv1');
    const targets = p.targets ?? [];
    const mask = key => targets.map(t => (key in t ? '1' : '0')).join('');
    expected.push(`prim ${i} layout=(${layout.join(' ')}) skin=${skin ?? '#f'} targets=${targets.length} normals=${mask('NORMAL')} tangents=${mask('TANGENT')}`);
});

// ---- the reader, through the probe ----
const src = path.join(root, 'test', 'probes', 'gltf-p1.ss');   // a probe, not a suite file: test/*.ss must answer one expect line
const wasm = path.join(dir, 'probe.wasm');
try {
    execFileSync(path.join(root, 'bin/goeteiac'), [src, wasm], { cwd: root, stdio: 'pipe' });
} catch (e) {
    require_(false, 'the probe compiles', String(e.stderr || e.stdout || e));
    process.exit(1);
}
const r = spawnSync(process.execPath, [path.join(root, 'rt', 'run.mjs'), wasm], { cwd: root, encoding: 'utf8' });
require_(r.status === 0, 'the probe runs', `${r.stdout}\n${r.stderr}`);
const got = r.stdout.trim().split('\n');
const width = Math.max(expected.length, got.length);
for (let i = 0; i < width; i++)
    require_(got[i] === expected[i], `line ${i + 1} agrees with the independent parse`,
             `reader:   ${JSON.stringify(got[i])}\nexpected: ${JSON.stringify(expected[i])}`);

if (!failed) console.log('gltf-p1: ok');
process.exit(failed ? 1 : 0);
