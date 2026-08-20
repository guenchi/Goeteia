// The sine polynomial lives ONCE, in src/prelude.ss; everything else
// binds it.  Procedure identity cannot be asserted on the wasm target
// (a top-level function used as a value is wrapped in a fresh closure
// struct at every reference site), so the single-supply requirement is
// checked where it is decidable: the source text of the whole library
// and compiler, not just the two files that happen to be involved
// today -- a second copy added in a third file is the case this test
// exists to catch.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function* sources(dir) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) yield* sources(p);
        else if (/\.(ss|sc|sls)$/.test(e.name)) yield p;
    }
}

// What identifies a sine series is its Taylor denominators, not any
// one literal: 210.0 alone is a HUD width in gfx/stats.ss and 2pi
// alone is circle-generation data in gfx/mesh.ss, so scanning for
// those would need per-file exemptions -- and an exempted checker
// rots.  A real second copy carries the whole run of denominators
// whatever it calls itself, and nothing else in the tree does.
// ("$sin-poly" keeps its sigil: lib/gfx/mat.ss legitimately has
// $mat-asin-poly, the INVERSE-trig series, whose name contains the
// looser substring.)
// Counting bare literals is not enough either: gfx/stats.ss happens
// to contain 20.0, 72.0 and 210.0 as HUD layout numbers.  What no
// layout code does is nest CONSECUTIVE denominators in ascending
// order a few characters apart, which is precisely how the series is
// written -- so that ordered adjacency is the signature.
const DENOMS = ['20.0', '42.0', '72.0', '110.0', '156.0', '210.0'];
const PAIRS = DENOMS.slice(0, -1).map((d, i) => [d, DENOMS[i + 1]]);
const esc = s => s.replace('.', '\\.');
const seriesRuns = t => PAIRS.filter(
    ([a, b]) => new RegExp(`${esc(a)}[\\s\\S]{0,200}${esc(b)}`).test(t)).length;
const HOME = path.join(root, 'src/prelude.ss');

const home = fs.readFileSync(HOME, 'utf8');
assert.equal(seriesRuns(home), PAIRS.length,
    'src/prelude.ss lost part of the sine series');
assert.ok(home.includes('$sin-poly'), 'src/prelude.ss lost $sin-poly');

for (const dir of ['lib', 'src']) {
    for (const file of sources(path.join(root, dir))) {
        if (file === HOME) continue;
        const text = fs.readFileSync(file, 'utf8');
        const n = seriesRuns(text);
        assert.equal(n, 0,
            `${path.relative(root, file)} nests ${n} consecutive pair(s) of the `
            + `sine series' Taylor denominators -- a second trig implementation; `
            + `it must live only in src/prelude.ss`);
        assert.ok(!text.includes('$sin-poly'),
            `${path.relative(root, file)} names $sin-poly -- the implementation `
            + 'must live only in src/prelude.ss');
    }
}

// the matrix library binds the prelude's FLONUM layer: the R6RS
// entries would add a widening step and cost these per-frame callers
// the f64 parameter specialization
const mat = fs.readFileSync(path.join(root, 'lib/gfx/mat.ss'), 'utf8');
for (const alias of ['(define (flsin x) ($sin-fl (fl* x 1.0)))',
                     '(define (flcos x) ($cos-fl (fl* x 1.0)))',
                     '(define (fltan x) ($tan-fl (fl* x 1.0)))']) {
    assert.ok(mat.includes(alias), `lib/gfx/mat.ss lacks "${alias}"`);
}

console.log('trig single-supply: ok');
