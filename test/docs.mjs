// Documentation claims this batch is responsible for, checked where
// they live rather than anywhere in the tree: `cmd-clear!` and `mod`
// occur in several files already, so a whole-repo grep would pass on
// text that has nothing to do with these sections.  Each assertion
// below is scoped to the section it belongs to.
//
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');

// the text under `heading`, up to the next heading of the same level
function section(text, heading) {
    const level = heading.match(/^#+/)[0].length;
    const lines = text.split('\n');
    const start = lines.findIndex(l => l.trim() === heading);
    assert.notEqual(start, -1, `no section titled ${JSON.stringify(heading)}`);
    const rest = lines.slice(start + 1);
    const stop = rest.findIndex(l => /^#+ /.test(l)
                                    && l.match(/^#+/)[0].length <= level);
    return (stop === -1 ? rest : rest.slice(0, stop)).join('\n');
}

test('the R6RS name table carries this batch\'s rows', () => {
    // core.md is the always-injected prompt substrate and lives under a
    // hard byte budget (docs/llm/manifest.json), so this table is a
    // compact index: each row must name the trap, and the accuracy
    // prose it points at is asserted separately, against limits.md.
    const s = section(read('docs/llm/core.md'), '## Coming from R6RS');
    assert.match(s, /\|\s*you reach for\s*\|\s*what to write\s*\|/);
    const row = name => {
        const line = s.split('\n').find(
            l => l.startsWith('|') && l.includes(name));
        assert.ok(line, `no table row mentions ${name}`);
        return line;
    };
    // the narrowed div/mod contract
    assert.match(row('`mod` `div`'), /exact integers only/);
    // modulo is NOT mod, and the row must carry the difference rather
    // than the name alone: "modulo is mod" would send a reader down
    // the negative-divisor path with the wrong value and green tests
    // the row must say `mod` is not it AND that they part company on a
    // negative divisor; the values themselves are pinned at run time
    // in test/divmod.ss ((mod 7 -2) = 1 against R5RS modulo's -1)
    const modulo = row('`modulo`');
    assert.match(modulo, /none/);
    assert.match(modulo, /negative divisor/);
    // sin/cos: the bound WITH its domain -- unqualified it is false
    const trig = row('`sin` `cos`');
    assert.match(trig, /1e-9/);
    assert.match(trig, /1e6/);
    // tan: no bound, plus the pointer to where the reason lives
    const tan = row('| `tan` |');
    assert.match(tan, /no absolute error bound/i);
    assert.match(tan, /docs\/limits\.md/);
    // the mat names, and that they are one implementation
    const fltrig = row('`flsin` `flcos` `fltan`');
    assert.match(fltrig, /\(gfx mat\)/);
    assert.match(fltrig, /same implementation/i);
    assert.match(row('`expt`'), /literal|multiply/);
    assert.match(row('`fx-clear!`'), /`cmd-clear!`/);
});

test('limits.md carries the accuracy claims core.md points at', () => {
    // The full statements live here because core.md cannot afford
    // them; every claim this batch is answerable for is pinned in
    // this section, not in the index that links to it.
    const s = section(read('docs/limits.md'), '## Trigonometric accuracy');
    // sin/cos: bound, domain, and the measured degradation past it
    assert.match(s, /1e-9/);
    assert.match(s, /1e6/);
    // the measured pair, both halves: a magnitude with no input to
    // attach it to is not a measurement anyone can re-run
    assert.match(s, /2\.4e-8/);
    assert.match(s, /2\^29/);
    // tan: no bound at all, with the first-order reason
    assert.match(s, /no absolute bound/i);
    assert.match(s, /ds\/c - s\*dc\/c\^2/);
    assert.match(s, /1\/cos\^2/);
    // the far-from-pole counterexample: a large argument alone breaks
    // the sin/cos bound, which "away from the poles" would hide
    assert.match(s, /942508/);
    // the poles, both of them, with the sign hazard and both oracles
    // both oracles, and -- crucially -- WHICH SIDE gets which sign:
    // "opposite sign" plus two figures would stay green on a table
    // that swapped them, and the swap is exactly the error a reader
    // would act on
    assert.match(s, /1\.63e16/);
    assert.match(s, /`\+inf`\s*\|\s*~?`?1\.63e16/);
    assert.match(s, /`-inf`\s*\|\s*~?`?\+5\.4e15/);
    assert.match(s, /exactly.{0,20}zero/is);
    // and that the (gfx mat) names inherit all of it
    assert.match(s, /flsin/);
});

test('verify.md states the mock world\'s capability surface', () => {
    const s = section(read('docs/verify.md'), '### What the world can and cannot do');
    // fetch: present but poisoned -- and why typeof probing is useless
    assert.match(s, /no network in the mock world/);
    assert.match(s, /typeof fetch/);
    // fetch-direct? judges JSPI, not the network
    assert.match(s, /fetch-direct\?/);
    assert.match(s, /JSPI/);
    // the clocks, stated as they actually behave: Date.now is pinned
    // forever while performance.now advances per pumped frame -- a
    // bare /frozen/ would pass on the wrong description of either
    assert.match(s, /`Date\.now` answers one constant/);
    assert.match(s, /`performance\.now`[\s\S]{0,80}pumps a frame/);
    assert.match(s, /Math\.random/);
    assert.match(s, /seeded|same sequence/i);
});

test('verify.md documents the spec-key whitelist and the 2d context', () => {
    const spec = section(read('docs/verify.md'), '## The check spec');
    assert.match(spec, /refused \*\*by name\*\*|refused by name/);
    assert.match(spec, /exit 2/);
    assert.match(spec, /`custom: \[\]`/);
    const world = section(read('docs/verify.md'), '## The mock world');
    assert.match(world, /getContext\("2d"\)/);
    assert.match(world, /8 px per code point/);
});

// ---- the manual on the website names libraries and procedures that exist ----
//
// docs/manual.md lives in the website branch (../04-goeteia-website),
// so nothing in this tree used to open it: it named `(web gl)` for a
// library that exists only as `(gfx gl)`, thirty-five times, and a
// `(web audio)` that exists as `(aud sfx)`, and no cell ever red.  Two
// checks, both derived from the tree rather than from a list kept by
// hand: every `(ns name)` the manual writes must be a file
// lib/ns/name.ss, and every `procedure: (name ...)` head must be a
// name some library exports or the prelude defines.  Where the
// website checkout is absent the check announces itself and stands
// down, so a missing sibling reads as "not run", never as "passed".
const here = path.dirname(fileURLToPath(import.meta.url));
const manualPath = path.join(here, '..', '..', '04-goeteia-website', 'docs', 'manual.md');
if (!fs.existsSync(manualPath)) {
    console.log('NOT EXERCISED HERE (the website checkout ../04-goeteia-website/docs/manual.md is not beside this tree; clone the website branch there to run the manual checks)');
} else {
    const manual = fs.readFileSync(manualPath, 'utf8');
    const libRoot = path.join(here, '..', 'lib');
    test('every library the manual names is a file under lib/', () => {
        const seen = new Map();
        for (const m of manual.matchAll(/\((web|gfx|aud) ([a-z0-9-]+)\)/g)) {
            const key = `(${m[1]} ${m[2]})`;
            seen.set(key, (seen.get(key) || 0) + 1);
        }
        const missing = [...seen].filter(([k]) => {
            const [, ns, name] = k.match(/^\((\w+) ([a-z0-9-]+)\)$/);
            return !fs.existsSync(path.join(libRoot, ns, `${name}.ss`));
        });
        assert.deepStrictEqual(missing, [], `libraries the manual names that do not exist: ${missing.map(([k, n]) => `${k} x${n}`).join(', ')}`);
    });
    test('every procedure the manual documents is exported by a library or defined by the prelude', () => {
        const known = new Set();
        // an export list ends at its matching paren, whatever comments follow
        const exportsOf = src => {
            const i = src.indexOf('(export');
            if (i < 0) return [];
            let depth = 0, j = i;
            for (; j < src.length; j++) { if (src[j] === '(') depth++; else if (src[j] === ')' && --depth === 0) break; }
            return src.slice(i + 7, j).replace(/;[^\n]*/g, ' ').split(/[\s()]+/).filter(n => n && n !== 'rename');
        };
        const walk = d => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else if (e.name.endsWith('.ss')) for (const n of exportsOf(fs.readFileSync(p, 'utf8'))) known.add(n); } };
        walk(libRoot);
        const prelude = fs.readFileSync(path.join(here, '..', 'src', 'prelude.ss'), 'utf8');
        for (const m of prelude.matchAll(/^\(define \(?([^\s()]+)/gm)) known.add(m[1]);
        for (const m of prelude.matchAll(/^\(define-syntax ([^\s()]+)/gm)) known.add(m[1]);
        // record types define their constructor, predicate and accessors
        for (const m of prelude.matchAll(/\(define-record-type\s*\(([^)]*)\)([\s\S]*?)\n\(/g)) {
            for (const n of m[1].split(/\s+/)) if (n) known.add(n);
            for (const f of m[2].matchAll(/\((?:immutable|mutable)\s+[^\s()]+\s+([^\s()]+)(?:\s+([^\s()]+))?/g)) { known.add(f[1]); if (f[2]) known.add(f[2]); }
        }
        // compiler primitives are registered as (name . arity) pairs, special forms as (cons 'name ...)
        const compiler = fs.readFileSync(path.join(here, '..', 'src', 'compiler.ss'), 'utf8');
        for (const m of compiler.matchAll(/\(([^\s()]+) \. [0-9]+\)/g)) known.add(m[1]);
        for (const m of compiler.matchAll(/\(cons '([^\s()]+)/g)) known.add(m[1]);
        const heads = [];
        for (const line of manual.split('\n')) {
            if (!line.startsWith('procedure:')) continue;
            for (const m of line.matchAll(/\(([^\s()]+)/g)) heads.push(m[1]);
        }
        const unknown = [...new Set(heads)].filter(h => !known.has(h) && !/^(quote|lambda|let|define|if|set!|begin)$/.test(h));
        assert.deepStrictEqual(unknown, [], `procedure heads the manual documents that nothing defines: ${unknown.join(', ')}`);
    });
}
