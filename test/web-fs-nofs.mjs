// (web fs) on a host that has no filesystem.
//
// test/web-fs.ss runs where files exist, so it can only assert the
// happy path and the caller's own mistakes.  The other body -- a
// browser page, and the verify and compile hosts, where every open
// returns -1 -- is the one the library documents a contract for, and
// a documented contract nothing exercises is a comment.
//
// So this file instantiates the same program against exactly those
// stubs, on both targets, and requires that every entry point answers
// BY NAME:
//
//   fs-exists?          -> #f, and no raise: on a host with no
//                          filesystem nothing exists, which is true
//   the readers         -> raise naming themselves (the path may be
//                          missing or the host may have none, and the
//                          two are indistinguishable from inside)
//   the writers         -> raise naming themselves (a failed WRITE
//                          open is not ambiguous: a host with a
//                          filesystem accepts the open and defers any
//                          failure to the close)
//
// What must NOT happen is a trap: a wasm trap from %fwrite on a -1
// descriptor takes the whole run down with no path and no name in it,
// which is the failure mode this library exists to remove.  A trap
// here surfaces as the module rejecting rather than as the expected
// line, so it cannot pass unnoticed.
//
// Copyright (c) 2026 guenchi.  MIT license; see LICENSE.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { pathToFileURL, fileURLToPath } from 'node:url';
import { makeJsBridge, callMain } from '../rt/jsbridge.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-fs-nofs-'));

let failed = false;
function require_(cond, message, detail) {
    if (cond) return;
    failed = true;
    console.error(`web-fs-nofs: ${message}`);
    if (detail !== undefined) console.error(detail);
}

const SRC = `
(import (rnrs) (web fs))
(define (who thunk)
  (guard (e ((error? e) (condition-who e))
            (#t 'not-a-condition))
    (thunk)
    'no-error))
(display (fs-exists? "/anything"))
(display " ")
(display (who (lambda () (fs-slurp! "/anything" 0 16))))
(display " ")
(display (who (lambda () (fs-size "/anything"))))
(display " ")
(display (who (lambda () (fs-slurp-string "/anything"))))
(display " ")
(display (who (lambda () (fs-spit! "/anything" 0 0))))
(display " ")
(display (who (lambda () (fs-spit-string! "/anything" "x"))))
`;

const WANT = '#f fs-slurp! fs-size fs-slurp-string fs-spit! fs-spit-string!';

const src = path.join(dir, 'nofs.ss');
const wasm = path.join(dir, 'nofs.wasm');
const js = path.join(dir, 'nofs.js');
fs.writeFileSync(src, SRC);
execFileSync(path.join(root, 'bin/goeteiac'), [src, wasm],
             { cwd: root, stdio: 'pipe' });
execFileSync(path.join(root, 'bin/goeteiac'), ['--js', src, js],
             { cwd: root, stdio: 'pipe' });

// the stubs rt/web.mjs gives a browser page, verbatim
const noFilesystem = out => ({
    write_byte: b => out.push(b),
    read_byte: () => -1,
    path_byte: () => {},
    open_read: () => -1,
    open_write: () => -1,
    fread: () => -1,
    fwrite: () => {},
    fclose: () => {},
});

async function runWasm() {
    const out = [];
    let exportsRef = null;
    const { instance } = await WebAssembly.instantiate(
        fs.readFileSync(wasm),
        { io: noFilesystem(out), js: makeJsBridge(() => exportsRef) });
    exportsRef = instance.exports;
    await callMain(instance.exports);
    return Buffer.from(out).toString('utf8').trim();
}

async function runJs() {
    const out = [];
    const m = await import(pathToFileURL(js).href);
    m.main(noFilesystem(out));
    return Buffer.from(out).toString('utf8').trim();
}

let wasmText;
try {
    wasmText = await runWasm();
} catch (e) {
    wasmText = `<trapped: ${e.message}>`;
}
require_(wasmText === WANT, 'the wasm target must name every entry point',
         `wanted ${JSON.stringify(WANT)}, got ${JSON.stringify(wasmText)}`);

let jsText;
try {
    jsText = await runJs();
} catch (e) {
    jsText = `<threw: ${e.message}>`;
}
require_(jsText === WANT, 'the JS target must name every entry point',
         `wanted ${JSON.stringify(WANT)}, got ${JSON.stringify(jsText)}`);

if (!failed) console.log('web-fs-nofs: ok');
process.exit(failed ? 1 : 0);
