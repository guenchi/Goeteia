// The JS fallback kept in a file of its own, where code generation from
// strings is refused (ledger R87, batch M49).
//
// loadGoeteiaAuto(url, 'x.mjs') fetched the file and ran its text with
// new Function, which a Content-Security-Policy without 'unsafe-eval'
// refuses.  It imports the module instead.  Two launches of one URL must
// still get two runtimes: the Function route gave each launch a fresh
// scope, and an import of one URL twice hands back one module.  When the
// import itself fails -- a server that sends the file as a type no module
// may have; here, a URL scheme node cannot import -- the old route is
// tried, and when that fails too the error names both causes.  The inline
// form (a selector for an inert script tag) has no way to run text
// without eval and keeps the Function route; that it still fails under
// the flag is pinned too, because the documentation says so.
//
// The file runs twice: as it is, where the old route still works, and
// under --disallow-code-generation-from-strings.
//
// ON THE TREE BEFORE THE CHANGE the run under the flag fails: the first
// launch dies with an EvalError.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const FLAG = '--disallow-code-generation-from-strings';
const here = fileURLToPath(import.meta.url);
const root = fileURLToPath(new URL('..', import.meta.url));
const mode = process.argv[2];

if (mode === undefined) {
    const env = { ...process.env };
    delete env.NODE_TEST_CONTEXT;
    let bad = 0;
    for (const [m, flags] of [['plain', []], ['no-eval', [FLAG]]]) {
        const r = spawnSync(process.execPath, [...flags, here, m],
                            { env, encoding: 'utf8' });
        process.stdout.write(r.stdout || '');
        process.stderr.write(r.stderr || '');
        if (r.status !== 0) {
            console.error(`FAIL the ${m} run exited ${r.status}` +
                          (r.signal ? ` (${r.signal})` : ''));
            bad = 1;
        }
    }
    process.exit(bad);
}

// each run is the run it says it is
if (mode === 'no-eval') {
    assert.throws(() => eval('1'), EvalError);
    assert.throws(() => Function('return 1'), EvalError);
} else {
    assert.equal(eval('1'), 1);
}

const { compileSource } = await import('../rt/compile.mjs');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-fallback-'));
process.on('exit', () => fs.rmSync(dir, { recursive: true, force: true }));

// a program that tells a fresh runtime from a reused one: it reads a
// per-instance global before it sets it
const text = await compileSource(
    '(import (rnrs) (web js))\n' +
    '(display (js-truthy? (js-get (js-global) "__goeteia_probe")))\n' +
    '(js-set! (js-global) "__goeteia_probe" 1)\n',
    { baseDir: root, target: 'js' });
fs.writeFileSync(path.join(dir, 'fallback.mjs'), text);
const moduleText = fs.readFileSync(path.join(dir, 'fallback.mjs'), 'utf8');

// what a page gives the loader: where it is, a fetch, a document
const SCHEME = 'goeteia-test:';
globalThis.location = { search: '?goeteia=js',
                        href: pathToFileURL(dir + path.sep).href };
globalThis.fetch = async href => {
    const u = String(href);
    const file = u.startsWith(SCHEME)
        ? path.join(dir, u.slice(SCHEME.length))
        : fileURLToPath(u);
    const body = fs.readFileSync(file, 'utf8');
    return { ok: true, text: async () => body };
};
globalThis.document = { querySelector: () => ({ textContent: moduleText }) };

const { loadGoeteiaAuto, loadGoeteia } = await import('../rt/web.mjs');
const output = () => {
    const s = Buffer.from(loadGoeteia._out).toString('utf8');
    loadGoeteia._out.length = 0;
    return s;
};
const failures = [];
async function launch(fallback) {
    try {
        await loadGoeteiaAuto('absent.wasm', fallback);
        return null;
    } catch (e) {
        return e;
    }
}

// two launches of one URL: two runtimes
loadGoeteia._out.length = 0;
const a1 = await launch('fallback.mjs');
const a2 = await launch('fallback.mjs');
const twice = output();
if (a1 || a2 || twice !== '#f#f') {
    failures.push(`two launches of one URL: got ${JSON.stringify(twice)}` +
                  `, want "#f#f"; errors: ${a1 && a1.message} / ` +
                  `${a2 && a2.message}`);
}

// an import that fails falls back to the old route
const b = await launch(SCHEME + 'fallback.mjs');
const bOut = output();
if (mode === 'plain') {
    if (b || bOut !== '#f') {
        failures.push(`old route after a failed import: got ` +
                      `${JSON.stringify(bOut)}, error ${b && b.message}`);
    }
} else if (!b || !/goeteia-test/.test(b.message) ||
           !/Code generation from strings disallowed/.test(b.message)) {
    failures.push(`both routes refused: the error must name the import ` +
                  `and the refused eval; got ${b ? JSON.stringify(b.message)
                                                 : 'no error'}`);
}

// the inline form keeps the Function route
const c = await launch('script[type="goeteia/js"]');
const cOut = output();
if (mode === 'plain') {
    if (c || cOut !== '#f') {
        failures.push(`inline form: got ${JSON.stringify(cOut)}, ` +
                      `error ${c && c.message}`);
    }
} else if (!c || !(c instanceof EvalError)) {
    failures.push(`inline form under ${FLAG}: want an EvalError, got ` +
                  `${c ? c.constructor.name + ': ' + c.message : 'none'}`);
}

if (failures.length) {
    console.error(`FAIL (${mode}):`);
    for (const f of failures) console.error('  ' + f);
    process.exit(1);
}
console.log(`ok (${mode}): two launches, the fallback route, the inline form`);
