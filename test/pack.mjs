// rt/pack.mjs: one .ss in, one self-contained .html out.
//
// The claim a packaged page makes is not "it was written" but "what
// ships is the program you verified, and it fetches nothing".  So the
// assertions here go through the artifact: the module is read back OUT
// of the HTML text and run, and its trace signature is compared with
// the compiled module's -- same frames, same readable state.  "It did
// not throw" would be satisfied by a page that silently draws nothing.
//
// Fixtures are test/pages/: static.ss and gradient.ss must package (a
// DOM page and a drawing page, since the emitted page hosts both), and
// unclosed.ss and trap.ss must not -- one failing before there are any
// bytes to embed, one after, which are different reports.
//
// Truncate or re-encode the payload and the byte-for-byte check goes
// red; break the inlined loader's syntax and the `node --check` of the
// page's own module script goes red.  Neither is reachable by looking
// at the bytes the packager happens to still hold in memory, which is
// why the self-check does not.
//
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { extractWasm, packageFile, renderPage, selfCheck } from '../rt/pack.mjs';

const PAGES = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)), 'pages');
const page = name => path.join(PAGES, name);

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-pack-test-'));
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const failed = r => (r.checks || []).filter(c => !c.ok).map(c => c.detail).join('\n');

test('a DOM page packages into one file that carries the same program', async () => {
    const out = path.join(tmp, 'static.html');
    const r = await selfCheck(page('static.ss'), { outFile: out });
    assert.equal(r.ok, true, failed(r));
    assert.ok(r.checks.length >= 6, 'the self-check should have made every claim');
    assert.ok(fs.existsSync(out), 'the artifact must be on disk');

    const html = fs.readFileSync(out, 'utf8');
    assert.match(html, /<div id="app">/);
    assert.match(html, /<canvas id="c" width="800" height="600">/);
    assert.match(html, /<title>static<\/title>/, 'the title defaults to the base name');
    // the page's own claim: nothing is fetched, not even the module.
    // The loader still CONTAINS the fetch-based entry points it has in
    // rt/web.mjs -- they are simply never reached, because the launch
    // block reads the payload off the page and calls runGoeteiaBytes
    // with it.  What must not appear is a URL to reach for.
    assert.doesNotMatch(html, /\bfetch\s*\(\s*['"`]/, 'no literal URL is fetched');
    assert.doesNotMatch(html, /https?:\/\//);
    assert.doesNotMatch(html, /^\s*import\s/m, 'the loader must be inlined, not imported');
    assert.match(html, /getElementById\("goeteia-module"\)[\s\S]*runGoeteiaBytes\(bytes\)/,
        'the module must come off the page itself');
});

test('a drawing page packages, and the embedded bytes draw the same frames', async () => {
    const r = await selfCheck(page('gradient.ss'), {});
    assert.equal(r.ok, true, failed(r));
    assert.ok(r.stats.draws > 0, 'the self-check ran the page, it did not just parse it');
    assert.ok(r.stats.html_bytes > r.stats.wasm_bytes,
        'base64 plus the loader cannot be smaller than the module');
});

test('a source that does not compile is reported before anything is embedded', async () => {
    const out = path.join(tmp, 'unclosed.html');
    const r = await selfCheck(page('unclosed.ss'), { outFile: out });
    assert.equal(r.ok, false);
    assert.equal(r.stage, 'compile');
    assert.equal(r.checks.length, 0);
    assert.equal(r.errors[0].line, 4, 'the compile diagnostic must survive the trip');
    assert.equal(fs.existsSync(out), false, 'no artifact may be left behind');
});

test('a page that traps is caught by the self-check, not shipped', async () => {
    const r = await selfCheck(page('trap.ss'), {});
    assert.equal(r.ok, false);
    assert.equal(r.stage, 'selfcheck');
    // it packaged fine -- the bytes match -- and then failed to run
    assert.equal(r.checks[0].ok, true, 'the payload itself is intact');
    const ran = r.checks.filter(c => /\bruns?:/.test(c.detail));
    assert.equal(ran.length, 2);
    assert.ok(ran.every(c => !c.ok), 'both the module and the embedded copy must fail');
    assert.match(ran[0].detail, /illegal cast/);
});

test('a truncated payload is caught by reading the artifact back', async () => {
    const p = await packageFile(page('static.ss'), null, {});
    assert.equal(p.ok, true);
    assert.equal(Buffer.compare(extractWasm(p.html), Buffer.from(p.wasm)), 0);

    // the same page rendered around one byte less: this is the shape
    // of every payload defect (a truncated write, a mangled re-encode),
    // and comparing against the in-memory bytes would never see it
    const short = renderPage(p.wasm.subarray(0, p.wasm.length - 1));
    assert.equal(extractWasm(short).length, p.wasm.length - 1);
    assert.notEqual(Buffer.compare(extractWasm(short), Buffer.from(p.wasm)), 0);
});

test('a page with no payload, or a payload that is not base64, is refused', () => {
    assert.throws(() => extractWasm('<html></html>'), /no goeteia\/wasm payload/);
    const bad = renderPage(Buffer.from([0, 1, 2]))
        .replace(/(<script type="goeteia\/wasm" id="goeteia-module">)/, '$1!!');
    assert.throws(() => extractWasm(bad), /not base64/);
});
