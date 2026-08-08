// pack.mjs -- one .ss in, one self-contained .html out.
//
//   goeteia pack <file.ss> <out.html> [--title T] [--script] [--selfcheck]
//   node rt/pack.mjs <file.ss> <out.html> [...]
//
// The page makes ZERO network requests.  The compiled module rides in
// an inert <script type="goeteia/wasm"> as base64 and the loader is
// inlined, so the file works from file:// and survives being mailed
// around.
//
// The loader is not reinvented: it is rt/jsbridge.mjs plus rt/web.mjs
// with the module plumbing stripped -- byte for byte the construction
// rt/compile.mjs uses for a `conjure` mount point's inline glue (see
// its conjureGlue()).  Following that one keeps the packaged page on
// the same bridge the rest of the toolchain is tested against; a
// second, hand-written bridge would drift.  Entry is runGoeteiaBytes,
// which is what loadGoeteia itself calls once it has the bytes -- we
// already have them, so no fetch (not even of a data: URI) happens.
//
// The page provides exactly the two hosts rt/verify.mjs's mock world
// provides: <div id="app"> and <canvas id="c">.
//
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { ROOT, compile, scenario, signature, drawStats } from './verify.mjs';

// ---- the inline runtime ------------------------------------------
// same transformation as rt/compile.mjs's conjureGlue(): drop the
// jsbridge import (the two files become one scope) and the export
// keywords (this is a classic script body, not a module)
export function inlineRuntime() {
    const strip = t => t.split('\n')
        .filter(l => !/^\s*import\s.*jsbridge/.test(l))
        .join('\n')
        .replace(/^export /gm, '');
    const jb = fs.readFileSync(path.join(ROOT, 'rt/jsbridge.mjs'), 'utf8');
    const wb = fs.readFileSync(path.join(ROOT, 'rt/web.mjs'), 'utf8');
    return strip(jb) + '\n' + strip(wb);
}

const esc = s => String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

export const PAYLOAD_ID = 'goeteia-module';
const RE_PAYLOAD =
    /<script type="goeteia\/wasm" id="goeteia-module">([\s\S]*?)<\/script>/;

// Pull the module back out of a packaged page.  The self-check reads
// the artifact through this, never through the bytes it happens to
// still hold in memory: what ships is what must be verified.
export function extractWasm(html) {
    const m = String(html).match(RE_PAYLOAD);
    if (!m) throw new Error('this HTML carries no goeteia/wasm payload');
    const b64 = m[1].trim();
    if (!/^[A-Za-z0-9+/=\s]*$/.test(b64))
        throw new Error('the payload is not base64');
    return Buffer.from(b64, 'base64');
}

export function renderPage(wasm, { title = 'Goeteia', width = 800, height = 600 } = {}) {
    const b64 = Buffer.from(wasm).toString('base64');
    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; padding: 2rem; font-family: system-ui, sans-serif;
         line-height: 1.6; display: flex; flex-direction: column;
         align-items: center; gap: 1rem; }
  #app { max-width: 46rem; width: 100%; }
  canvas { max-width: 100%; border-radius: 10px; }
  #goeteia-error { color: #b00; white-space: pre-wrap; font-family: ui-monospace, monospace; }
</style>
</head>
<body>
<div id="app"></div>
<canvas id="c" width="${width}" height="${height}"></canvas>
<pre id="goeteia-error" hidden></pre>
<script type="goeteia/wasm" id="${PAYLOAD_ID}">${b64}</script>
<script type="module">
${inlineRuntime()}

// ---- launch ----
const b64 = document.getElementById(${JSON.stringify(PAYLOAD_ID)}).textContent.trim();
const bin = atob(b64);
const bytes = new Uint8Array(bin.length);
for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
runGoeteiaBytes(bytes).catch(e => {
  const box = document.getElementById('goeteia-error');
  box.hidden = false;
  box.textContent = 'Goeteia: ' + (e && e.message ? e.message : e);
});
</script>
</body>
</html>
`;
}

export async function packageFile(sourceFile, outFile, opts = {}) {
    const c = await compile(sourceFile, opts);
    if (!c.ok) return { ok: false, stage: 'compile', errors: c.errors };
    const html = renderPage(c.wasm, {
        title: opts.title || path.basename(sourceFile, path.extname(sourceFile)),
        width: opts.width, height: opts.height,
    });
    if (outFile) fs.writeFileSync(outFile, html);
    return { ok: true, html, wasm: c.wasm, outFile,
             stats: { wasm_bytes: c.wasm.length, html_bytes: Buffer.byteLength(html) } };
}

// ---- the self-check ----------------------------------------------
// Package, then read the module back OUT of the HTML and smoke it in
// the same mock world rt/verify.mjs uses.  Equivalence is asserted on
// the trace signature -- same frames, same readable state -- not on
// "it did not throw": a page that silently draws nothing would pass
// that.  A truncated or re-encoded payload fails here.
export async function selfCheck(sourceFile, opts = {}) {
    const p = await packageFile(sourceFile, opts.outFile || null, opts);
    if (!p.ok) return { ok: false, stage: 'compile', errors: p.errors, checks: [] };

    const checks = [];
    const add = (ok, detail) => checks.push({ ok, detail });

    let back;
    try { back = extractWasm(p.html); }
    catch (e) { return { ok: false, stage: 'extract', checks: [{ ok: false, detail: e.message }] }; }

    add(Buffer.compare(back, Buffer.from(p.wasm)) === 0,
        `the wasm extracted from the HTML is byte for byte the compiled module `
        + `(${back.length} bytes in the page, ${p.wasm.length} compiled)`);

    const direct = await scenario(p.wasm);
    const embedded = await scenario(back);
    add(direct.ok, `the compiled module runs: ${direct.ok ? 'yes'
        : 'threw ' + (direct.error && direct.error.message)}`);
    add(embedded.ok, `the bytes taken back out of the HTML run: ${embedded.ok ? 'yes'
        : 'threw ' + (embedded.error && embedded.error.message)}`);
    if (direct.ok && embedded.ok)
        add(signature(direct) === signature(embedded),
            'both produce the same frame command stream and readable state');

    // the page must not reach the network for anything
    const external = [...p.html.matchAll(/\b(?:src|href)\s*=\s*"([^"]+)"/g)]
        .map(m => m[1])
        .filter(u => !/^(#|data:|javascript:)/.test(u));
    add(external.length === 0,
        external.length === 0 ? 'the page has no external references'
                              : `the page still references: ${external.join(', ')}`);
    add(!/\bfetch\s*\(\s*['"`]https?:/.test(p.html),
        'the inlined loader issues no http request');

    // The mock world runs the module through the SAME bridge but not
    // through this page's script text, so a page whose inlined loader
    // does not even parse would still pass every check above.  Parse
    // it for real.
    const mod = p.html.match(/<script type="module">([\s\S]*?)<\/script>/);
    if (!mod) add(false, 'the page carries no module script');
    else {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-pack-'));
        const tmp = path.join(dir, 'page.mjs');
        fs.writeFileSync(tmp, mod[1]);
        const r = spawnSync(process.execPath, ['--check', tmp], { encoding: 'utf8' });
        fs.rmSync(dir, { recursive: true, force: true });
        add(r.status === 0,
            r.status === 0 ? "the page's inlined module script is valid JavaScript"
                : `the page's inlined module script does not parse: `
                  + `${(r.stderr || '').split('\n').slice(0, 3).join(' ')}`);
    }

    return {
        ok: checks.every(c => c.ok),
        stage: checks.every(c => c.ok) ? 'done' : 'selfcheck',
        checks,
        stats: { ...p.stats, ...drawStats(direct) },
    };
}

// ---------------------------------------------------------------- //
// CLI
// ---------------------------------------------------------------- //

export const PACK_USAGE = `Usage: goeteia pack <file.ss> <out.html> [options]
  --title <T>    the page title (default: the source's base name)
  --script       compile with -O0 (faster, for quick feedback)
  --selfcheck    after packing, take the module back out of the page and
                 prove it behaves identically; out.html may be omitted
Exit status: 0 packed (and, with --selfcheck, verified), 1 failed, 2 bad usage.`;

function printErrors(errors) {
    for (const e of errors || []) {
        const where = e.file
            ? `${e.file}${e.line ? ':' + e.line : ''}${e.col ? ':' + e.col : ''}: ` : '';
        console.error(`  FAIL ${e.stage || 'compile'}: ${where}${e.message}`);
        if (e.excerpt) console.error(e.excerpt.replace(/^/gm, '       '));
        if (e.hint) console.error(`       hint: ${e.hint}`);
    }
}

export async function runPack(argv) {
    const args = {};
    const pos = [];
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a === '--selfcheck' || a === '--script') args[a.slice(2)] = true;
        else if (a === '--help' || a === '-h') { console.log(PACK_USAGE); return 0; }
        else if (a.startsWith('--')) {
            const v = argv[++i];
            if (v === undefined) {
                console.error(`goeteia pack: ${a} needs a value\n${PACK_USAGE}`);
                return 2;
            }
            args[a.slice(2)] = v;
        }
        else pos.push(a);
    }
    if (!pos[0] || (!pos[1] && !args.selfcheck)) { console.error(PACK_USAGE); return 2; }
    const opts = { script: !!args.script, title: args.title };

    if (args.selfcheck) {
        const r = await selfCheck(pos[0], { ...opts, outFile: pos[1] || null });
        for (const c of r.checks) console.log(`  ${c.ok ? 'ok  ' : 'FAIL'} ${c.detail}`);
        printErrors(r.errors);
        console.log(r.ok ? `ok   ${pos[0]}: the packaged page carries the same program`
                         : `FAIL ${pos[0]} (stage ${r.stage})`);
        return r.ok ? 0 : 1;
    }

    const r = await packageFile(pos[0], pos[1], opts);
    if (!r.ok) { printErrors(r.errors); return 1; }
    console.log(`${pos[1]}: wasm ${r.stats.wasm_bytes} bytes -> HTML ${r.stats.html_bytes} bytes`);
    return 0;
}

if (process.argv[1] &&
    import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href)
    runPack(process.argv.slice(2)).then(c => process.exit(c));
