// The (web ...) libraries where code generation from strings is refused
// (ledger R87, batch M49): a page under a Content-Security-Policy without
// 'unsafe-eval'.
//
// node's --disallow-code-generation-from-strings refuses eval, indirect
// eval and Function, and still instantiates wasm and imports modules --
// what a policy of script-src 'self' 'wasm-unsafe-eval' leaves a page.
// This file runs itself again under that flag, and every program below
// is compiled and run inside that process, on both targets.  The first
// thing the flagged process does is prove the flag took: eval and
// Function must throw there, or nothing after it means anything.
//
// What is checked: every (web ...) library loads -- the list is read
// from lib/web, so a library added later is covered without an edit
// here; ->js of #t and #f are the JavaScript booleans themselves; (web
// sexpr) writes and reads flonums; (web fetch) builds its options and
// headers objects and reads a missing header as #f; (web rpc) builds the
// POST it sends; (web react) adopts or installs its registry.
//
// ON THE TREE BEFORE THE CHANGE (d38f5af, measured) 54 of the 72 cases
// fail.  Importing (web js) evaluates "true" and "false" while it loads,
// so the 13 libraries that reach it, directly or through another, die
// with an EvalError (args canvas dom fetch glyphs js react rpc scroll
// sexpr sse sx ws), and so does every case after the loading ones; the
// 18 that pass are the loads of the 9 libraries that never import it
// (component css frac fs html json reactive typeset utf8).

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const FLAG = '--disallow-code-generation-from-strings';
const here = fileURLToPath(import.meta.url);
const root = fileURLToPath(new URL('..', import.meta.url));

if (!process.execArgv.includes(FLAG)) {
    // the flagged run reports through its own exit status; it must not
    // talk the test runner's protocol to the runner of this file
    const env = { ...process.env };
    delete env.NODE_TEST_CONTEXT;
    const r = spawnSync(process.execPath, [FLAG, here],
                        { env, encoding: 'utf8' });
    process.stdout.write(r.stdout || '');
    process.stderr.write(r.stderr || '');
    if (r.status !== 0) {
        console.error(`FAIL the run under ${FLAG} exited ${r.status}` +
                      (r.signal ? ` (${r.signal})` : ''));
        process.exit(1);
    }
    process.exit(0);
}

// the flag took: without this the cases below prove nothing
assert.throws(() => eval('1'), EvalError);
assert.throws(() => (0, eval)('1'), EvalError);
assert.throws(() => Function('return 1'), EvalError);

const { compileSource } = await import('../rt/compile.mjs');
const { makeJsBridge, callMain } = await import('../rt/jsbridge.mjs');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-no-eval-'));
process.on('exit', () => fs.rmSync(tmp, { recursive: true, force: true }));

function makeIo(out) {
    return {
        write_byte: b => out.push(b), read_byte: () => -1,
        path_byte: () => {}, open_read: () => -1, open_write: () => -1,
        fread: () => -1, fwrite: () => {}, fclose: () => {},
    };
}

let serial = 0;
async function run(target, source) {
    const out = [];
    if (target === 'wasm') {
        const bytes = await compileSource(source, { baseDir: root });
        let exportsRef = null;
        const { instance } = await WebAssembly.instantiate(bytes, {
            io: makeIo(out), js: makeJsBridge(() => exportsRef),
        });
        exportsRef = instance.exports;
        await callMain(instance.exports);
    } else {
        const text = await compileSource(source,
                                         { baseDir: root, target: 'js' });
        const file = path.join(tmp, `p${serial++}.mjs`);
        fs.writeFileSync(file, text);
        const m = await import(pathToFileURL(file).href);
        m.main(makeIo(out));
    }
    await new Promise(r => setImmediate(r));
    return Buffer.from(out).toString('utf8');
}

const TARGETS = ['wasm', 'js'];
const failures = [];
let cases = 0;
async function check(name, target, source, expect) {
    cases++;
    let got;
    try {
        got = await run(target, source);
    } catch (e) {
        got = `raised ${e && e.constructor && e.constructor.name}: ` +
              `${e && e.message}`;
    }
    if (got !== expect) {
        failures.push(`${name} [${target}]: got ${JSON.stringify(got)}, ` +
                      `want ${JSON.stringify(expect)}`);
    }
    return got === expect;
}
function judge(name, target, ok) {
    cases++;
    if (!ok) failures.push(`${name} [${target}]`);
}

// ---- every (web ...) library loads
const webDir = path.join(root, 'lib', 'web');
const libraries = fs.readdirSync(webDir).filter(f => f.endsWith('.ss'))
    .sort().map(f => {
        const m = fs.readFileSync(path.join(webDir, f), 'latin1')
            .match(/^\s*\(library \(web ([^\s()]+)\)/m);
        assert.ok(m, `lib/web/${f} holds no (web ...) library`);
        return m[1];
    });
assert.ok(libraries.length >= 22,
          `only ${libraries.length} (web ...) libraries found`);
for (const lib of libraries) {
    for (const t of TARGETS) {
        await check(`(web ${lib}) loads`, t,
                    `(import (rnrs) (web ${lib}))\n(display "loaded")\n`,
                    'loaded');
    }
}

// ---- #t and #f cross as the booleans, not as values that merely test true
globalThis.probeTrue = true;
globalThis.probeFalse = false;
for (const t of TARGETS) {
    await check('->js of #t and #f', t,
                '(import (rnrs) (web js))\n' +
                '(display (list (js-eq? (->js #t) (js-get (js-global) "probeTrue"))\n' +
                '               (js-eq? (->js #f) (js-get (js-global) "probeFalse"))\n' +
                '               (js-truthy? (->js #f))))\n',
                '(#t #t #f)');
}

// ---- (web sexpr): flonums written and read
for (const t of TARGETS) {
    await check('sexpr flonums', t,
                '(import (rnrs) (web sexpr))\n' +
                '(define (from-bytes l) (bytevector-ieee-double-ref (u8-list->bytevector l) 0 \'little))\n' +
                '(display (sexpr->string (list (from-bytes \'(0 0 0 0 0 0 248 63))\n' +
                '                              (from-bytes \'(0 0 0 0 0 0 0 128))\n' +
                '                              (from-bytes \'(0 0 0 0 0 0 240 127)))))\n' +
                '(display " ")\n' +
                '(let ((v (string->sexpr "#f8\\"AAAAAAAA8D8=\\"")))\n' +
                '  (display (list (flonum? v) (fl=? v 1.0))))\n',
                '(#f8"AAAAAAAA+D8=" #f8"AAAAAAAAAIA=" #f8"AAAAAAAA8H8=") (#t #t)');
}

// ---- (web fetch) and (web rpc): the objects they hand to fetch
const fetchLog = [];
globalThis.fetch = (url, opts) => {
    fetchLog.push({
        url: String(url),
        method: opts && opts.method,
        headers: opts && opts.headers ? { ...opts.headers } : undefined,
        body: opts && opts.body,
    });
    return new Promise(() => {});
};
globalThis.probeResponse = new Response('x', { headers: { 'X-Id': '7' } });
for (const t of TARGETS) {
    fetchLog.length = 0;
    await check('fetch: options, headers, a missing header', t,
                '(import (rnrs) (web js) (web fetch))\n' +
                '(fetch "/f" \'((method . "PUT") (headers . (("X-A" . "b")))))\n' +
                '(display (list (response-header (js-get (js-global) "probeResponse") "X-Id")\n' +
                '               (response-header (js-get (js-global) "probeResponse") "Nope")\n' +
                '               (boolean? (fetch-direct?))))\n',
                '(7 #f #t)');
    const sent = fetchLog[fetchLog.length - 1];
    judge('fetch: what reached fetch', t,
          sent !== undefined && sent.url === '/f' && sent.method === 'PUT' &&
          sent.headers !== undefined && sent.headers['X-A'] === 'b' &&
          Object.keys(sent.headers).length === 1);

    fetchLog.length = 0;
    await check('rpc!: the POST', t,
                '(import (rnrs) (web js) (web rpc))\n' +
                '(rpc! "/rpc" \'(add 1 2) (lambda (v) v))\n' +
                '(display "sent")\n',
                'sent');
    const post = fetchLog[fetchLog.length - 1];
    judge('rpc!: what reached fetch', t,
          post !== undefined && post.url === '/rpc' && post.method === 'POST' &&
          post.headers !== undefined &&
          post.headers['Content-Type'] === 'application/sexpr' &&
          post.body === '(add 1 2)');
}

// ---- (web react): the registry adopted, installed, or replaced
const register =
    '(import (rnrs) (web js) (web react))\n' +
    '(react-component "Solo" (lambda (container props) (lambda () #f)))\n' +
    '(display "registered")\n';
for (const t of TARGETS) {
    // an object already there is adopted, with what it holds
    const held = { kept: 1 };
    globalThis.__goeteia = held;
    await check('react: adopts an object', t, register, 'registered');
    judge('react: adopts an object (contents)', t,
          globalThis.__goeteia === held && held.kept === 1 &&
          typeof held.Solo === 'function');

    // nothing there: one is installed
    delete globalThis.__goeteia;
    await check('react: installs one', t, register, 'registered');
    judge('react: installs one (contents)', t,
          typeof globalThis.__goeteia === 'object' &&
          globalThis.__goeteia !== null &&
          typeof globalThis.__goeteia.Solo === 'function');

    // a value that holds no properties is replaced
    globalThis.__goeteia = 5;
    await check('react: replaces a number', t, register, 'registered');
    judge('react: replaces a number (contents)', t,
          typeof globalThis.__goeteia === 'object' &&
          typeof globalThis.__goeteia.Solo === 'function');

    // M49 ruling: a function holds properties as an object does, and is
    // adopted (typeof answered 'function' and it used to be replaced)
    const f = function registry() {};
    globalThis.__goeteia = f;
    await check('react: adopts a function', t, register, 'registered');
    judge('react: adopts a function (contents)', t,
          globalThis.__goeteia === f && typeof f.Solo === 'function');
}

if (failures.length) {
    console.error(`FAIL ${failures.length} of ${cases} cases under ${FLAG}:`);
    for (const f of failures) console.error('  ' + f);
    process.exit(1);
}
console.log(`ok ${cases} cases under ${FLAG}`);
