#!/usr/bin/env node
// Compile one source to both targets and print the two-artifact
// mount section: the wasm module for WasmGC engines, the --js
// fallback riding inline, rt/web.mjs's loadGoeteiaAuto picking at
// load time.  The assembly itself lives in (web embed) -- this tool
// compiles a small driver against it and runs it on the JS target,
// so the CLI and any site generator share one implementation.
//
//   goeteia-mount app.ss [-o mount.html] [--embed-wasm]
//                 [--wasm-url URL] [--rt URL]
//
// By default the fragment references app.wasm next to the page
// (lean: it fetches and caches separately); --embed-wasm inlines the
// module as a data: URI for a fully self-contained page.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'fs';
import os from 'os';
import path from 'path';
import { pathToFileURL } from 'url';
import { compileToBytes, compileSource } from '../rt/compile.mjs';
import { runJsModule } from '../rt/runjs.mjs';

function usage() {
    console.error(
        'usage: goeteia-mount <app.ss> [-o out.html] [--embed-wasm]'
        + ' [--wasm-url URL] [--rt URL]');
    process.exit(1);
}

const argv = process.argv.slice(2);
let src = null, out = null, embedWasm = false;
let wasmUrl = null, rtUrl = './rt/web.mjs';
for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-o') out = argv[++i];
    else if (a === '--embed-wasm') embedWasm = true;
    else if (a === '--wasm-url') wasmUrl = argv[++i];
    else if (a === '--rt') rtUrl = argv[++i];
    else if (!src) src = a;
    else usage();
}
if (!src) usage();
if (!wasmUrl) wasmUrl = path.basename(src).replace(/\.ss$/, '.wasm');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-mount-'));
try {
    const wasmFile = path.join(dir, 'app.wasm');
    const jsFile = path.join(dir, 'app.js');
    fs.writeFileSync(wasmFile, await compileToBytes(src));
    fs.writeFileSync(jsFile, await compileToBytes(src, { target: 'js' }));

    // string literal for the driver source: paths are tmpdir-safe,
    // but escape anyway
    const q = s => '"' + String(s).replace(/[\\"]/g, c => '\\' + c) + '"';
    const driver =
        '(import (rnrs) (web embed))\n' +
        '(define (read-data path)\n' +
        '  (string-for-each (lambda (c) (%path-byte (char->integer c))) path)\n' +
        '  (let ((fd (%open-read)))\n' +
        '    (when (< fd 0) (error (quote mount) "cannot read" path))\n' +
        '    (let loop ((acc (quote ())) (n 0))\n' +
        '      (let ((b (%fread fd)))\n' +
        '        (if (< b 0)\n' +
        '            (begin (%fclose fd)\n' +
        '                   (let ((bv (make-bytevector n 0)))\n' +
        '                     (let fill ((bs acc) (i (- n 1)))\n' +
        '                       (if (null? bs) bv\n' +
        '                           (begin (bytevector-u8-set! bv i (car bs))\n' +
        '                                  (fill (cdr bs) (- i 1)))))))\n' +
        '            (loop (cons b acc) (+ n 1)))))))\n' +
        '(define (bytes->text bv)\n' +
        '  (let* ((n (bytevector-length bv)) (s (make-string n)))\n' +
        '    (let loop ((i 0))\n' +
        '      (if (= i n) s\n' +
        '          (begin (string-set! s i (integer->char (bytevector-u8-ref bv i)))\n' +
        '                 (loop (+ i 1)))))))\n' +
        '(display (mount-html (bytes->text (read-data ' + q(jsFile) + '))\n' +
        (embedWasm
            ? '                     (read-data ' + q(wasmFile) + ')\n'
            : '                     ' + q(wasmUrl) + '\n') +
        '                     ' + q(rtUrl) + '))\n';

    const driverFile = path.join(dir, 'driver.mjs');
    fs.writeFileSync(driverFile, await compileSource(driver, {
        baseDir: path.dirname(path.resolve(src)),
        name: 'mount-driver',
        target: 'js',
    }));
    const { text } = await runJsModule(driverFile);
    if (out) fs.writeFileSync(out, text);
    else process.stdout.write(text);
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
