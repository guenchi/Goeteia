// pack.mjs -- one .ss in, one self-contained .html out.
//
//   goeteia pack <file.ss> <out.html> [--title T] [--script] [--selfcheck]
//   node rt/pack.mjs <file.ss> <out.html> [...]
//
// The compiled module rides in an inert <script type="goeteia/wasm"> as
// base64 and the loader is inlined, so the file works from file:// and
// survives being mailed around.
//
// This used to open by saying the page makes ZERO network requests.
// That is the intent, and it was not asserted by anything: what the
// self-check actually holds a page to is three narrower things -- no
// external reference in the markup attributes externalRefs scans, no
// literal http(s) URL passed to fetch, and byte equality between what
// was verified and what was written.  A request assembled at run time
// (`const u = 'side.wasm'; fetch(u)`) passes all three.
//
// DELIBERATELY NOT CLOSED HERE: proving the stronger claim needs a
// run-time observation -- load the page in a headless browser and read
// the network log -- which is an observation surface this batch does
// not build.  The claim above is therefore stated as the three checks
// and not as their conclusion; see the checks in selfCheck().
//
// The loader is not reinvented: it is rt/jsbridge.mjs plus rt/web.mjs
// with the module plumbing stripped -- the same construction
// rt/compile.mjs uses for a `conjure` mount point's inline glue (see
// its conjureGlue()).  Following that one keeps the packaged page on
// the same bridge the rest of the toolchain is tested against; a
// second, hand-written bridge would drift.
//
// NOT byte for byte, and this used to claim it was.  conjureGlue()
// additionally flattens every character above 126 to a space, because
// its output is embedded in a Scheme string literal; there are three
// such characters in the runtime today (a Gamma and two dashes/arrows
// in comments), so the two texts differ in exactly three places.  The
// STRIPPING is what is shared -- the import lines and the `export`
// keywords -- and that is what "following it" means here.  Entry is runGoeteiaBytes,
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

// The URLs a page names in its MARKUP, in the attributes listed below,
// so a caller can assert there are none.  The attribute may be quoted
// three ways and spelled in any case -- an earlier version matched only
// lowercase double quotes, so `<script src='side.js'>` in a shipped
// page went unseen.  Exported because that is a rule with several
// members and the only honest way to show they are all covered is to
// feed it each one.
//
// WHAT IT SCANS, precisely, because the name of a check is a promise:
// the attributes src, href, srcset and poster.  Not CSS `url(...)`, not
// a URL assembled by script, not `<meta http-equiv=refresh>`.  Those
// pages would reach out and this returns nothing for them; the check
// built on this must be named for the attributes, not for the page's
// whole network behaviour.
// Tags only, recognized in ONE pass.  This used to be two regex
// replaces run in sequence -- strip comments, then strip script bodies
// -- and each pass was blind to the context the other one defines.
// That cost three holes, all of the same shape and all of them found by
// review rather than by the tests:
//
//   <script data-x=">" src="side.js">        a > inside a quoted
//                                            attribute ended `[^>]*`
//   <!-- <script> --><img src=x><!-- </script> -->
//                                            fake tags in a comment
//                                            paired around real markup
//   <script>const x='<!--';</script><img src=x><!-- -->
//                                            a comment opener inside
//                                            script TEXT ate to the
//                                            next --> in the document
//
// Two of those were introduced by the fix for the one before it.  The
// lesson is not "handle the third case too": as long as there are two
// independent recognizers of where markup is, a document can be built
// that they disagree about.  So there is one now.  It walks the
// document, and at `<` decides among three things -- a comment, a
// raw-text element, an ordinary tag -- which is the same decision a
// parser makes, made once.
function tagsOf(html) {
    const s = String(html);
    const out = [];
    let i = 0;
    // the end of the tag that starts at `at`, quote-aware, so a `>`
    // inside an attribute value does not end it
    const tagEnd = (at) => {
        let j = at + 1, q = null;
        for (; j < s.length; j++) {
            const c = s[j];
            if (q) { if (c === q) q = null; }
            else if (c === '"' || c === "'") q = c;
            else if (c === '>') return j;
        }
        return s.length - 1;
    };
    while (i < s.length) {
        if (s[i] !== '<') { i++; continue; }
        if (s.startsWith('<!--', i)) {
            // The two ABRUPT CLOSINGS come first.  HTML ends a comment
            // at `<!-->` and `<!--->` -- there is no `-->` in either --
            // so searching for one runs off the end and swallows the
            // whole rest of the document.  `<!--><img src=x>` returned
            // nothing while a browser fetches the image: the same shape
            // as the script-text `<!--` hole, one odd-looking construct
            // silently switching the scan off for everything after it.
            if (s[i + 4] === '>') { i += 5; continue; }
            if (s[i + 4] === '-' && s[i + 5] === '>') { i += 6; continue; }
            const e = s.indexOf('-->', i + 4);
            // an unterminated comment really does run to the end, which
            // is what a browser does with it too
            i = e < 0 ? s.length : e + 3;
            continue;
        }
        // script and style hold raw text; textarea and title hold RCDATA.
        // Markup inside any of them is not markup -- a browser does not
        // fetch `<textarea><img src=x></textarea>`, and reporting it
        // would be a false red on a correct page.
        // NAME-ENDS-HERE, and `\b` is not it: `\b` sits between the `t`
        // of script and the `-` of `<script-x>`, so a custom element
        // whose name merely starts with one of these was read as a
        // raw-text element and everything inside it went unseen.  This
        // is the same mistake `\b` made in the attribute matcher, in a
        // second place; and the closing scan below already had the rule
        // right, so one function held two spellings of one rule.
        const raw = /^<(script|style|textarea|title)(?=[\s/>]|$)/i
              .exec(s.slice(i, i + 10));
        const e = tagEnd(i);
        out.push(s.slice(i, e + 1));          // the tag itself is markup
        // No self-closing exception: HTML has none for these elements.
        // `<script src="a.js"/>` does NOT close -- the parser keeps
        // reading script text -- so treating the `/` as a close made
        // this scanner report markup the browser never sees.
        if (raw) {
            // ...and everything to the matching close tag is TEXT, not
            // markup, and not a place comments are recognized either
            // An end tag may carry attributes; they are a parse error
            // and the browser ignores them, but the tag still CLOSES.
            // `</script x>` was not recognized here, so everything
            // after it was eaten as script text.
            //
            // And it ends where tagEnd says, not at the first `>`:
            // `</script x="><img src=y>">` keeps that first `>` inside
            // a quoted value, so a browser sees no img.  Using `[^>]*>`
            // here was the SAME mistake already fixed for opening tags,
            // left standing in the other half of the pair -- the fix
            // and its twin, one file apart.
            const name = raw[1].toLowerCase();
            let j = e + 1;
            for (;;) {
                const at = s.toLowerCase().indexOf('</' + name, j);
                if (at < 0) { j = s.length; break; }
                const after = s[at + 2 + name.length];
                if (after === undefined || /[\s/>]/.test(after)) {
                    j = tagEnd(at) + 1;
                    break;
                }
                j = at + 2 + name.length;      // `</scriptfoo`, not a close
            }
            i = j;
        } else {
            i = e + 1;
        }
    }
    return out;
}

export function externalRefs(html) {
    const markup = tagsOf(html).join('\n');
    const strip = u => u.replace(/^["']|["']$/g, '');
    const drop = u => u === '' || /^(#|data:|javascript:)/i.test(u);

    const out = [];
    // `\b` is not an attribute-name boundary: it matches between the
    // `-` and the `s` of `data-src`, so a div carrying `data-src` was
    // reported as a fetch the browser never makes.  The name must not
    // be preceded by a word character or a hyphen.
    const single = /(?<![\w-])(?:src|href|poster)\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi;
    for (const m of markup.matchAll(single)) {
        const u = strip(m[1]);
        if (!drop(u)) out.push(u);
    }
    // srcset is a comma-separated candidate list, each candidate a URL
    // followed by an optional descriptor -- one attribute, many URLs,
    // which is why it cannot ride along with the ones above.
    const set = /(?<![\w-])srcset\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/gi;
    for (const m of markup.matchAll(set))
        for (const cand of strip(m[1]).split(',')) {
            const u = cand.trim().split(/\s+/)[0];
            if (u && !drop(u)) out.push(u);
        }
    return out;
}

// Pull the module back out of a packaged page.  The self-check reads
// the artifact through this, never through the bytes it happens to
// still hold in memory: what ships is what must be verified.
// CANONICAL base64 only.  Both ends of this wire are ours -- renderPage
// writes the payload with Buffer.toString('base64'), which emits one
// canonical spelling and no whitespace -- so anything else in the middle
// is a page that was edited or corrupted, and taking it silently is how
// a truncated payload becomes a wasm module that merely fails later.
// `Buffer.from(x, 'base64')` is famously forgiving: it skips characters
// it does not recognise, accepts a length that is not a multiple of
// four, and ignores what the padding says.  The checks below are the
// spelling rules that forgiveness hides:
//
//   * the alphabet, and nothing else -- whitespace included.  The old
//     test allowed \s explicitly; our packer never emits any, so a
//     payload carrying whitespace did not come from us;
//   * a length that is a multiple of four;
//   * padding only at the end, and at most two;
//   * the bits of the last character that no byte uses must be zero,
//     which is what makes "AAB=" wrong while "AAA=" is right.
//
// This is deliberately narrower than the reader in (igropyr sexpr),
// which accepts padding anywhere and is answering to a different
// contract -- there the wire comes from a peer, here it comes from us.
export function extractWasm(html) {
    const m = String(html).match(RE_PAYLOAD);
    if (!m) throw new Error('this HTML carries no goeteia/wasm payload');
    // TRIMMED first, on purpose.  renderPage writes the payload with no
    // whitespace around it, so a page that has some was reformatted --
    // an HTML tool reindenting around the tag touches what is OUTSIDE
    // the token, and that is a benign transformation to survive.
    // Whitespace INSIDE the payload is a different event: the token
    // itself was rewritten, which our encoder never does, and that is
    // refused below.
    const b64 = m[1].trim();
    const bad = () => { throw new Error('the payload is not base64'); };
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(b64)) bad();
    if (b64.length % 4 !== 0) bad();
    if (b64.length > 0) {
        // the leftover bits: one '=' leaves two unused bits in the last
        // character, two '=' leave four
        const pad = b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0;
        if (pad > 0) {
            const last = b64[b64.length - pad - 1];
            const v = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
                + '0123456789+/';
            const bits = v.indexOf(last);
            if (bits < 0 || (bits & (pad === 1 ? 0x03 : 0x0f)) !== 0) bad();
        }
    }
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

    // The page every check below reads is the one that SHIPS.  It used
    // to be p.html -- the string still in memory -- which verified an
    // object nobody ever opens: corrupt the write (`writeFileSync(
    // outFile, html.replace('AGFzbQ', 'BGFzbQ'))`) and every check
    // passed while the file on disk carried a broken magic.  Reading it
    // back for the PAYLOAD alone was not enough either: the external
    // references, the loader's fetch, the module script's syntax and
    // the byte count each had their own p.html, so a write that damaged
    // the script around an intact payload still passed all four.  One
    // name for the artifact, used everywhere -- with no outFile there is
    // nothing on disk and the in-memory page is the artifact.
    const shipped = p.outFile ? fs.readFileSync(p.outFile, 'utf8') : p.html;

    let back;
    try { back = extractWasm(shipped); }
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

    // Two DIFFERENT mechanisms, not one repeated.  This first one is
    // total: the artifact must be, character for character, the page
    // this run rendered.  Any edit between rendering and shipping fails
    // it whatever the edit was -- an inserted tag, a rewritten launch
    // block, a truncation -- which is what the property checks below
    // cannot promise, since each only knows the one shape it looks for.
    // What it cannot see is renderPage emitting a bad page in the first
    // place; that is what the property checks are for.  Neither
    // subsumes the other.
    if (p.outFile)
        add(shipped === p.html,
            shipped === p.html
                ? 'the file on disk is the page that was rendered'
                : `the file on disk is not the page that was rendered `
                  + `(${Buffer.byteLength(shipped)} bytes written, `
                  + `${Buffer.byteLength(p.html)} rendered)`);

    // Not "the page makes no network requests" -- see the header.  This
    // is the markup half of that: no URL in the attributes externalRefs
    // scans (src, href, srcset, poster).  CSS url(), a computed fetch
    // and <meta refresh> are outside it and outside the two checks that
    // follow, which is why the claim is stated as the checks.
    const external = externalRefs(shipped);
    add(external.length === 0,
        external.length === 0
            ? 'no external reference in the markup attributes scanned '
              + '(src, href, srcset, poster)'
                              : `the page still references: ${external.join(', ')}`);
    // Says exactly what it measures, which is less than "issues no
    // request": `const u = 'side.wasm'; fetch(u)` is invisible to any
    // regex, and the module is never executed here -- the mock world
    // runs the WASM through the bridge, not this page's script.  A
    // computed fetch inserted after rendering is caught by the equality
    // above; one that renderPage itself emitted would not be caught at
    // all, and saying so is better than implying otherwise.
    add(!/\bfetch\s*\(\s*['"`]https?:/.test(shipped),
        'no literal http(s) URL is passed to fetch');

    // The mock world runs the module through the SAME bridge but not
    // through this page's script text, so a page whose inlined loader
    // does not even parse would still pass every check above.  Parse
    // it for real.
    const mod = shipped.match(/<script type="module">([\s\S]*?)<\/script>/);
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
        // measured on the artifact, like everything above it
        stats: { ...p.stats, html_bytes: Buffer.byteLength(shipped),
                 ...drawStats(direct) },
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
