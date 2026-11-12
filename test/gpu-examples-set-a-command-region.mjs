// Every example that drives (gfx gpu) itself sets a command region below
// its own data (R52b: archive/goeteia-m28-2026-11-12.md).
//
// THE DEFECT.  (gfx gpu) sets no limit of its own (R52, M25): the encoder
// writes its words from the region's base for as long as a frame goes on.
// Six examples keep their data at fixed addresses -- uniforms at 4096,
// a table at 2048, vertices at 65536 -- and set no region, so a frame
// that grew past that address would write its command words over the
// data, silently, and the uploads would read the words.  Their frames
// are short today (15-62 words); an example is what people copy, and a
// copy grows.
//
// THE RULE.  An example that imports (gfx gpu) and does not call
// sgpu-init! (which sets [0, 64 KiB) itself) calls (gpu-region! 0 LIMIT)
// with LIMIT an integer -- a literal or a name the file defines as one --
// no greater than any address the file defines under a name ending in
// BASE.  A longer frame then raises the region overflow error instead.
//
// WHAT THIS CELL IS NOT.  It reads the sources; it does not run the
// examples (they need a page and a device), and it does not check that
// the committed .wasm beside each one was rebuilt -- the freshness of
// committed artifacts is its own ledger entry.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = path.join(root, 'examples');
// a source without its comments, so a commented-out call does not count
const code = (name) => fs.readFileSync(path.join(dir, name), 'utf8')
    .split('\n').map(l => l.replace(/;.*$/, '')).join('\n');
const drivers = fs.readdirSync(dir).filter(n => n.endsWith('.ss')).sort()
    .filter(n => { const s = code(n); return /\(gfx gpu\)/.test(s) && !/\(sgpu-init!/.test(s); });

// THE COUNT IS A ROW: an empty list satisfies "every one sets a region".
test('there are examples that drive (gfx gpu) themselves', () => {
    assert.ok(drivers.length >= 6, `found ${drivers.length}: ${drivers.join(' ')}`);
});

for (const name of drivers) {
    test(`${name} sets a command region below its data`, () => {
        const s = code(name);
        const defs = new Map();
        for (const m of s.matchAll(/\(define\s+([A-Za-z0-9_-]+)\s+(\d+)\s*\)/g)) defs.set(m[1], Number(m[2]));
        const value = (tok) => /^\d+$/.test(tok) ? Number(tok) : defs.get(tok);
        const calls = [...s.matchAll(/\(gpu-region!\s+(\S+)\s+([^\s()]+)\s*\)/g)];
        assert.ok(calls.length >= 1, `${name}: no (gpu-region! base limit) call`);
        const bases = [...defs].filter(([k]) => /BASE$/.test(k)).map(([, v]) => v);
        for (const c of calls) {
            assert.equal(value(c[1]), 0, `${name}: the region starts at ${c[1]}`);
            const lim = value(c[2]);
            assert.ok(Number.isInteger(lim), `${name}: the limit ${c[2]} is not an integer the file defines`);
            for (const b of bases)
                assert.ok(lim <= b, `${name}: the limit ${lim} lies above data at ${b}`);
        }
    });
}
