// docs/limits.md names the glTF texture slots that a model drawn with
// gltf-draw! and the library's own shaders never shows.
//
// (gfx gltf) loads every material texture slot a file carries and
// uploads each one.  What gltf-draw! does with them is not uniform:
//   - the base colour texture is bound to u_tex;
//   - the normal, emissive and occlusion textures are bound to u_nmap,
//     u_emap and u_omap, but ONLY when the program declares that
//     sampler -- a program that does not declare it gets nothing, and
//     no error;
//   - the metallic-roughness texture is uploaded and never bound.
// Of the library's shaders, only mesh-normal-fs declares u_nmap, and
// none declares u_emap or u_omap.  So a model drawn with the library's
// shaders shows no metallic-roughness, emissive or occlusion map, and
// nothing at the draw says so.  That is a limit, and a limit belongs in
// docs/limits.md.
//
// WHY A CELL AND NOT A SENTENCE.  Both halves of that answer move: a
// slot wired into gltf-draw! later leaves the "never bound" set, and a
// library shader that learns to declare u_omap takes occlusion out of
// the "no library shader asks for it" set.  So the set is not written
// here; it is computed from the source, and every slot in it must be
// named in the limits.md section whose heading names gltf-draw!, along
// with the three sampler names a caller's program would declare.
//
// WHAT IT CANNOT SEE.  It checks NAMES, not sentences.  A section that
// named every slot and sampler while saying something false about each
// -- that metallic-roughness is bound, that the samplers are always
// bound -- would pass; what the section says about them is for review.
// Nor can it tell a stale mention of a slot that has since been wired
// from a sentence explaining that the slot is conditional: when a slot
// leaves the set, this stays green and the section may still say the old
// thing.
import { test } from 'node:test';
import assert from 'node:assert';
import { readFileSync, readdirSync } from 'node:fs';

const root = new URL('..', import.meta.url).pathname;
const read = p => readFileSync(root + p, 'utf8');
const gltf = read('lib/gfx/gltf.ss');
const limits = read('docs/limits.md');
const noComments = text => text.split('\n').filter(l => !/^\s*;/.test(l)).join('\n');

// internal accessor -> glTF slot name; the sampler, where gltf-draw! has
// one for that slot, is read from its bind calls below, not written here.
const SLOTS = {
    'gprim-mrtex': 'metallicRoughnessTexture',
    'gprim-ntex': 'normalTexture',
    'gprim-etex': 'emissiveTexture',
    'gprim-otex': 'occlusionTexture',
};

function drawBody() {
    const lines = gltf.split('\n');
    const at = lines.findIndex(l => /^\s{2}\(define \(gltf-draw! /.test(l));
    if (at < 0) return null;
    let end = lines.length;
    for (let i = at + 1; i < lines.length; i++)
        if (/^\s{2}\(define[\s(]/.test(lines[i])) { end = i; break; }
    return noComments(lines.slice(at, end).join('\n'));
}

function section() {
    const lines = limits.split('\n');
    const at = lines.findIndex(l => /^#{1,6}\s/.test(l) && l.includes('gltf-draw!'));
    if (at < 0) return null;
    const level = lines[at].match(/^#+/)[0].length;
    let end = lines.length;
    for (let i = at + 1; i < lines.length; i++) {
        const m = lines[i].match(/^(#+)\s/);
        if (m && m[1].length <= level) { end = i; break; }
    }
    return lines.slice(at, end).join('\n');
}

// Every sampler name declared by a library shader, from the source of
// lib/gfx: (uniform sampler2D NAME).
function librarySamplers() {
    const names = new Set();
    for (const f of readdirSync(root + 'lib/gfx').filter(f => f.endsWith('.ss')))
        for (const m of noComments(read('lib/gfx/' + f)).matchAll(/\(uniform\s+sampler2D\s+([A-Za-z_]\w*)\)/g))
            names.add(m[1]);
    return names;
}

const body = drawBody();
// (bind (gprim-ntex p) 1 'u_nmap) -> ntex is bound conditionally on u_nmap
const conditional = {};
for (const m of (body || '').matchAll(/\(bind \((gprim-[a-z]+) p\) \d+ '([A-Za-z_]\w*)\)/g))
    conditional[m[1]] = m[2];
const declared = librarySamplers();
const unshown = Object.keys(SLOTS).filter(a => {
    if (!(body || '').includes(a)) return true;
    const sampler = conditional[a];
    return sampler !== undefined && !declared.has(sampler);
}).map(a => SLOTS[a]).sort();

test('gltf-draw! is found, and its conditional binds are read', () => {
    assert.ok(body, 'no (define (gltf-draw! ...) in lib/gfx/gltf.ss');
    assert.match(body, /'u_tex\b/, 'gltf-draw! no longer binds u_tex; this cell reads the wrong body');
    assert.ok(Object.keys(conditional).length >= 1,
        'no (bind (gprim-...tex p) unit \'sampler) call found in gltf-draw!; the shape this cell reads has changed');
});

test('docs/limits.md has a section on gltf-draw!', () => {
    assert.ok(section(), 'no heading in docs/limits.md names gltf-draw!, so nothing tells a reader '
        + 'that these maps are loaded and not shown: ' + unshown.join(', '));
});

test('that section names every slot the library never shows', () => {
    const s = section() || '';
    const missing = unshown.filter(n => !s.includes(n));
    assert.deepStrictEqual(missing, [], `gltf-draw! with the library's shaders never shows ${JSON.stringify(unshown)}; `
        + `the section does not name ${JSON.stringify(missing)}`);
});

test('that section names the samplers a caller\'s program would declare', () => {
    const s = section() || '';
    const missing = Object.values(conditional).filter(n => !s.includes(n));
    assert.deepStrictEqual(missing, [], `the section does not name ${JSON.stringify(missing)}`);
});

// CONTROL for the computation, against what was read by hand on
// 2026-09-25: metallic-roughness is never bound, emissive and occlusion
// are bound on samplers no library shader declares, and normal is bound
// on u_nmap, which mesh-normal-fs declares.  If the source moves, this is
// the row that says the computation, not the documentation, changed.
test('CONTROL the computed set matches the reading of 2026-09-25', () => {
    assert.ok(declared.has('u_nmap'), 'no library shader declares u_nmap any more');
    assert.deepStrictEqual(unshown, ['emissiveTexture', 'metallicRoughnessTexture', 'occlusionTexture']);
});
