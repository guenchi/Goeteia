// Every exported name is listed in docs/api.md, and nothing is listed
// there that no library exports.
//
// The manual explains what a library is for; it cannot mention every
// name, and measuring it showed how far that falls short.  Measured on
// the libraries this test scrapes: 823 exported names, of which 449
// appear nowhere in the manual and 236 appear in it exactly once -- in
// a document of several thousand lines, which is the same as not at
// all.  A capability nobody can find is a capability that gets written
// again downstream, which is exactly what happened: a consumer rebuilt
// frustum culling, an input layer and a joint palette that all already
// existed, and the three names they needed were mentioned zero, once
// and once.
//
// Those counts move as libraries are added, so they are here as the
// reason this file exists, not as an assertion.  The assertion is
// below: every exported name is listed, and every listed name says
// something.
//
// So the index is generated and this test is the thing that keeps it
// true: add an export without listing it, or list one that is gone, and
// the suite says so.  A doc that drifts is worse than no doc, because
// the reader trusts it.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

export function exportsOf(source) {
    // (export a b c ...) up to the (import ...) that follows it
    const m = /\(export\s([\s\S]*?)\)\s*\(import/.exec(source);
    if (!m) return [];
    return m[1]
        .split('\n')
        .map(line => line.replace(/;.*$/, ''))       // strip trailing comments
        .join(' ')
        .split(/\s+/)
        .filter(Boolean);
}

function libraryFiles() {
    const out = [];
    for (const family of fs.readdirSync(path.join(root, 'lib')).sort()) {
        const dir = path.join(root, 'lib', family);
        if (!fs.statSync(dir).isDirectory()) continue;
        for (const f of fs.readdirSync(dir).sort()) {
            if (f.endsWith('.ss')) out.push([`(${family} ${f.slice(0, -3)})`, path.join(dir, f)]);
        }
    }
    return out;
}

const expected = new Map();
for (const [name, file] of libraryFiles()) {
    const names = exportsOf(fs.readFileSync(file, 'utf8'));
    if (names.length) expected.set(name, names);
}

// The index as it stands: "## (family name)" then one bullet per name,
// each carrying its description after an em dash.
const index = fs.readFileSync(path.join(root, 'docs/api.md'), 'utf8');
const listed = new Map();
const described = new Map();
let current = null;
for (const line of index.split('\n')) {
    const h = /^## `?\(([a-z0-9]+) ([a-z0-9-]+)\)`?/.exec(line);
    if (h) { current = `(${h[1]} ${h[2]})`; listed.set(current, []); continue; }
    if (!current) continue;
    const b = /^- `([^`]+)`\s+—\s*(.*)$/.exec(line.trimEnd());
    if (b) { listed.get(current).push(b[1]); described.set(`${current} ${b[1]}`, b[2]); }
}

// Ground the parser: these are names a consumer went looking for and
// did not find, plus a few that must never silently vanish.  If the
// export scraper ever stops working, this catches it before the
// comparison below turns into "empty equals empty".
const mustExist = [
    ['(gfx fx)', 'fx-init-input!'], ['(gfx fx)', 'key-down?'],
    ['(gfx gltf)', 'gltf-joint-palette!'], ['(gfx gl)', 'gl-texture-base-level!'],
    ['(gfx mat)', 'm4-frustum-planes'], ['(gfx mat)', 'sphere-in-frustum?'],
    ['(gfx gl)', 'cmd-uniform-matrices!'], ['(gfx reflect)', 'reflect-range'],
    ['(sim entity)', 'entity-spawn!'], ['(lng machine)', 'make-machine'],
];
for (const [lib, name] of mustExist) {
    assert.ok(expected.has(lib), `the export scraper found no library ${lib}`);
    assert.ok(expected.get(lib).includes(name),
              `the export scraper missed ${name} in ${lib}`);
}

const problems = [];
for (const [lib, names] of expected) {
    if (!listed.has(lib)) { problems.push(`docs/api.md has no section for ${lib}`); continue; }
    const there = new Set(listed.get(lib));
    for (const n of names) if (!there.has(n)) problems.push(`${lib} exports ${n}, docs/api.md does not list it`);
    const real = new Set(names);
    for (const n of listed.get(lib)) if (!real.has(n)) problems.push(`docs/api.md lists ${n} under ${lib}, which does not export it`);
}
for (const lib of listed.keys()) {
    if (!expected.has(lib)) problems.push(`docs/api.md has a section for ${lib}, which is not a library`);
}

// A name with no line beside it is the failure this file exists to
// prevent, one step further in: findable but still unreadable.  The
// index is what a reader consults when the manual does not mention a
// name at all -- 442 of them did not when it was written -- so a bare
// list would only move the dead end.  A placeholder counts as missing:
// generating one is how a new export announces that nobody has said
// what it does yet.
const PLACEHOLDER = /^TODO\b/;
for (const [lib, names] of expected) {
    for (const n of names) {
        const d = described.get(`${lib} ${n}`);
        if (d === undefined) continue;              // already reported above
        if (!d.trim()) problems.push(`${lib} ${n} has no description`);
        else if (PLACEHOLDER.test(d.trim())) problems.push(`${lib} ${n} still has a placeholder`);
        else if (d.trim().length < 12) problems.push(`${lib} ${n} has a description too short to say anything: "${d.trim()}"`);
    }
}

assert.deepEqual(problems, [], `\n${problems.slice(0, 40).join('\n')}${problems.length > 40 ? `\n... and ${problems.length - 40} more` : ''}`);
