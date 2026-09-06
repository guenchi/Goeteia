// The host side of an unhandled Scheme error: what a program wrote
// before it died, and the exception line itself, must reach the
// caller.  A program that raises an unhandled error prints
// "unhandled exception: who: message irritants" through io.write_byte
// and then traps (unreachable).  Both runners used to hand the host
// nothing but the trap -- RuntimeError: unreachable -- and drop the
// buffered output on the floor, so the one line that said what failed
// never surfaced; an embedding host had to instrument its program to
// find out which check tripped.
//
// Cases, on both targets:
//   * runModule / runJsModule reject with an Error whose message
//     carries the program's exception line, and whose `output`
//     property carries everything the program wrote before dying;
//   * the CLIs exit 1, print the program's output on stdout and the
//     exception line on stderr;
//   * a program that finishes normally is untouched (the control).
//
// Copyright (c) 2026 guenchi.  MIT license; see LICENSE.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-errors-'));

let failed = false;
function require_(cond, message, detail) {
    if (cond) return;
    failed = true;
    console.error(`run-errors: ${message}`);
    if (detail !== undefined) console.error(detail);
}

function build(name, source) {
    const src = path.join(dir, `${name}.ss`);
    const wasm = path.join(dir, `${name}.wasm`);
    const js = path.join(dir, `${name}.js`);
    fs.writeFileSync(src, source);
    execFileSync(path.join(root, 'bin/goeteiac'), [src, wasm], { cwd: root, stdio: 'pipe' });
    execFileSync(path.join(root, 'bin/goeteiac'), ['--js', src, js], { cwd: root, stdio: 'pipe' });
    return { wasm, js };
}

const dying = build('dying', `
(import (rnrs))
(display "checking joints...") (newline)
(error 'check-skin "joint index out of range" 42)
`);
const fine = build('fine', `(import (rnrs)) (display "all joints in range") (newline)`);

const LINE = 'check-skin: joint index out of range 42';
const OUTPUT = 'checking joints...\nunhandled exception: check-skin: joint index out of range 42\n';

// ---- the embedding API ----
for (const [label, start] of [
    ['wasm', () => runModule(fs.readFileSync(dying.wasm))],
    ['js', () => runJsModule(dying.js)],
]) {
    let err = null;
    try { await start(); } catch (e) { err = e; }
    require_(err instanceof Error, `${label}: an unhandled error rejects with an Error`);
    require_(err && String(err.message).includes(LINE),
             `${label}: the rejection's message carries the exception line`,
             `message: ${JSON.stringify(err && err.message)}`);
    require_(err && err.output === OUTPUT,
             `${label}: the rejection carries the program's output before it died`,
             `output: ${JSON.stringify(err && err.output)}`);
}

// ---- the CLIs ----
for (const [label, runner, file] of [
    ['wasm', 'run.mjs', dying.wasm],
    ['js', 'runjs.mjs', dying.js],
]) {
    const r = spawnSync(process.execPath, [path.join(root, 'rt', runner), file],
                        { cwd: root, encoding: 'utf8' });
    require_(r.status === 1, `${label} CLI: exit status 1 on an unhandled error`, `status ${r.status}`);
    require_(r.stdout.includes('checking joints...'),
             `${label} CLI: what the program wrote before dying reaches stdout`,
             `stdout: ${JSON.stringify(r.stdout)}`);
    require_(r.stderr.includes(LINE),
             `${label} CLI: the exception line reaches stderr`,
             `stderr: ${JSON.stringify(r.stderr)}`);
}

// ---- a silent trap: no exception line, the trap's own text ----
//
// A program that dies without going through the prelude's handler
// -- here, unbounded recursion -- prints no "unhandled exception:"
// line.  The runner then keeps the host's trap text as the message
// and still attaches what the program wrote, with the original
// exception as `cause`.
const deep = build('deep', `
(import (rnrs))
(display "before the overflow") (newline)
(define (down n) (+ 1 (down (+ n 1))))
(display (down 0))
`);
for (const [label, start] of [
    ['wasm', () => runModule(fs.readFileSync(deep.wasm))],
    ['js', () => runJsModule(deep.js)],
]) {
    let err = null;
    try { await start(); } catch (e) { err = e; }
    require_(err instanceof Error, `${label}: a silent trap rejects with an Error`);
    require_(err && err.output === 'before the overflow\n',
             `${label}: a silent trap still carries the output before it`,
             `output: ${JSON.stringify(err && err.output)}`);
    require_(err && err.cause instanceof Error && err.message.includes(err.cause.message),
             `${label}: with no exception line the message is the trap's own text and the cause is attached`,
             `message: ${JSON.stringify(err && err.message)} cause: ${String(err && err.cause)}`);
    require_(err && !err.message.includes('unhandled exception'),
             `${label}: a silent trap does not invent an exception line`);
}

// ---- the LAST exception line wins ----
//
// The line is recognized in the program's own output, so a program
// that prints an impostor before raising for real must still be
// reported with the real one: the prelude writes last.
const impostor = build('impostor', `
(import (rnrs))
(display "unhandled exception: impostor: not the real one") (newline)
(error 'real "the real one" 7)
`);
for (const [label, start] of [
    ['wasm', () => runModule(fs.readFileSync(impostor.wasm))],
    ['js', () => runJsModule(impostor.js)],
]) {
    let err = null;
    try { await start(); } catch (e) { err = e; }
    require_(err && err.message.includes('real: the real one 7') && !err.message.includes('impostor'),
             `${label}: the last exception line is the one reported`,
             `message: ${JSON.stringify(err && err.message)}`);
}

// ---- the control: a program that finishes is untouched ----
{
    const w = await runModule(fs.readFileSync(fine.wasm));
    const j = await runJsModule(fine.js);
    require_(w.text === 'all joints in range\n' && j.text === 'all joints in range\n',
             'a program that finishes still returns its text on both targets',
             JSON.stringify([w.text, j.text]));
}

if (!failed) console.log('run-errors: ok');
process.exit(failed ? 1 : 0);
