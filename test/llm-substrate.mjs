// docs/llm/ is the page substrate: the context a model is handed so
// that a page it has never written before compiles and runs the first
// time.  Documentation rots quietly, and a substrate that rots teaches
// the rot.  Two properties keep it honest, and this file asserts both.
//
//   1. Every tier document carries its example source BYTE FOR BYTE.
//      The ```scheme fence in tN-*.md is compared against
//      examples/tN.ss, so prose and code cannot drift apart: edit the
//      example and the document is stale until it is updated, edit the
//      document's code block and it no longer matches what was run.
//      (Only trailing blank lines are ignored -- a fenced block ends
//      at its closing fence, so it cannot carry them.)
//
//   2. Every example is put through `goeteia verify` -- all four
//      stages, compile, smoke, draw/interact, custom checks -- against
//      the check spec recorded for its tier in manifest.json.  The
//      specs live in the manifest rather than here, so adding a tier
//      is a new manifest entry plus a new example and document, and no
//      edit to this file.
//
// Byte counts and budgets are asserted too: the manifest is what a
// caller sizes an injection by, and a manifest that reports last
// month's sizes is worse than one that reports none.
//
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { verifyFile } from '../rt/verify.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const LLM = path.join(ROOT, 'docs/llm');

const read = f => fs.readFileSync(path.join(LLM, f), 'utf8');
const bytesOf = f => fs.statSync(path.join(LLM, f)).size;

const manifest = JSON.parse(read('manifest.json'));

// The one fenced Scheme block a tier document is built around.
function fencedScheme(md, name) {
    const m = md.match(/\n```scheme\n([\s\S]*?)\n```\n/);
    assert.ok(m, `${name} has no \`\`\`scheme block`);
    return m[1];
}

// THE DENOMINATOR.  Every other assertion in this file walks
// `manifest.files`, so what the manifest does not list, nothing here
// looks at -- a document could drift from its example, fail verify, or
// blow its budget for years and the suite would not say a word.
// Measured, not feared: dropping t5-animated.md from the manifest with
// the file still on disk left this whole suite green, and so did adding
// a document whose code block does not compile.
//
// Note which assertion SHOULD have caught that: the one named "the
// manifest describes the files that are actually there", which checked
// only that each listed file exists at its listed size -- manifest to
// disk, never disk to manifest.  A name that describes the missing
// check precisely is the reason nobody goes looking: its reader
// believes someone already did.
//
// So the two sets are compared here, both ways, and the failure names
// the file -- "the two sets differ" would only send its reader off to
// diff them by hand.
test('docs/llm: the directory holds exactly what the manifest lists', () => {
    const onDisk = new Set(
        fs.readdirSync(LLM).filter(f => f.endsWith('.md')));
    const listed = new Set(manifest.files.map(f => f.path));
    for (const f of onDisk)
        assert.ok(listed.has(f),
            `docs/llm/${f} is on disk and not in manifest.json -- nothing `
            + 'in this file checks it, so add a manifest entry or delete it');
    for (const f of listed)
        assert.ok(onDisk.has(f),
            `manifest.json lists ${f}, which is not in docs/llm/`);

    // examples/ the same way: an example nothing points at is checked
    // by nothing, exactly like an unlisted document.
    const exOnDisk = new Set(
        fs.readdirSync(path.join(LLM, 'examples'))
          .filter(f => f.endsWith('.ss'))
          .map(f => `examples/${f}`));
    const exListed = new Set(
        manifest.files.filter(f => f.example).map(f => f.example));
    for (const f of exOnDisk)
        assert.ok(exListed.has(f),
            `docs/llm/${f} is on disk and no manifest entry names it -- `
            + 'it is never compiled, never verified, never compared');
    for (const f of exListed)
        assert.ok(exOnDisk.has(f),
            `manifest.json names ${f}, which is not in docs/llm/examples/`);
});

test('docs/llm: the manifest describes the files that are actually there', () => {
    assert.ok(manifest.files.length >= 2, 'the manifest lists no documents');
    for (const f of manifest.files) {
        const real = bytesOf(f.path);
        assert.equal(f.bytes, real,
            `manifest says ${f.path} is ${f.bytes} bytes; it is ${real}`);
        assert.ok(real <= f.budget,
            `${f.path} is ${real} bytes, over its ${f.budget}-byte budget`);
        if (!f.example) continue;
        const ex = bytesOf(f.example);
        assert.equal(f.example_bytes, ex,
            `manifest says ${f.example} is ${f.example_bytes} bytes; it is ${ex}`);
    }
    const known = new Set(manifest.files.map(f => f.path));
    const by = Object.fromEntries(manifest.files.map(f => [f.path, f.bytes]));
    for (const inj of manifest.injection) {
        for (const f of inj.include)
            assert.ok(known.has(f), `injection "${inj.task}" includes unlisted ${f}`);
        assert.equal(inj.bytes, inj.include.reduce((n, f) => n + by[f], 0),
            `injection "${inj.task}" reports the wrong total size`);
    }
});

// "every tier document" is every document the MANIFEST lists.  That is
// the same thing as every document only because "docs/llm: the
// directory holds exactly what the manifest lists" says so -- named,
// not "see above", because assertions get moved.  Weaken or delete
// that one and this name goes quietly back to being false.
test('docs/llm: every tier document carries its example byte for byte', () => {
    const withExample = manifest.files.filter(f => f.example);
    assert.ok(withExample.length > 0, 'no tier document has an example');
    for (const f of withExample) {
        const source = read(f.example).replace(/\n+$/, '');
        assert.equal(fencedScheme(read(f.path), f.path), source,
            `${f.path}'s code block is not ${f.example} verbatim -- one of the two `
            + 'was edited without the other');
    }
});

// The four stages, on every example, against the tier's own spec.
// Compiling with the self-hosted compiler is a child process per
// example, so this is the slow test in the suite; it is also the only
// one that proves the substrate teaches code that runs.
// "every example" is every example the MANIFEST names, and it means
// every example for the same borrowed reason as the assertion above:
// "docs/llm: the directory holds exactly what the manifest lists".
test('docs/llm: every example passes goeteia verify', { timeout: 600000 }, async t => {
    for (const f of manifest.files.filter(x => x.example && x.checks)) {
        await t.test(f.example, async () => {
            const r = await verifyFile(path.join(LLM, f.example), f.checks);
            const why = (r.errors || [])
                .map(e => `${e.stage}: ${e.message}${e.hint ? ` (${e.hint})` : ''}`)
                .join('\n');
            assert.equal(r.ok, true, `${f.example} did not pass at stage ${r.stage}\n${why}`);
            // a spec nobody's checks reach would pass vacuously
            assert.ok(r.checks.length > 0, `${f.example} was judged by no checks at all`);
        });
    }
});
