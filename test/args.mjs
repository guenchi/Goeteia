// The host side of (web args): rt/run.mjs and rt/runjs.mjs hand a
// program its own argv.
//
// test/web-args.ss covers the library where no host published
// anything (zero arguments, and a named error out of range) and runs
// on every target the suite covers.  What it cannot cover from
// inside the suite is a NON-empty argv, because run-tests.sh invokes
// the runners without one -- so that half lives here, driving the
// two CLIs the way a user would.
//
// The cases are the ones a hand-rolled argv split gets wrong:
//
//   * no separator at all -- the invocation every other test uses,
//     which must keep meaning exactly what it meant before;
//   * a separator with nothing after it (zero arguments, not one
//     empty one);
//   * `--` appearing again INSIDE the program's arguments, which
//     must reach the program rather than re-split (a lastIndexOf
//     would lose the arguments before it);
//   * an argument with a space in it and one that is not ASCII,
//     which cross as one argument each and byte for byte;
//   * an input file AND arguments together, which is the whole point
//     of the second channel: a program that reads its settings from
//     the command line no longer has to carve them out of its data.
//
// Both targets answer the same oracle, the way every other pair of
// backends in this tree does.
//
// Copyright (c) 2026 guenchi.  MIT license; see LICENSE.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-args-'));

let failed = false;
function require_(cond, message, detail) {
    if (cond) return;
    failed = true;
    console.error(`args: ${message}`);
    if (detail !== undefined) console.error(detail);
}

// ---- the fixtures ----
const ECHO_SRC = `
(import (rnrs) (web args))
(display (args-count))
(for-each (lambda (a) (display " [") (display a) (display "]"))
          (args-list))
`;

// both channels at once: the arguments and the standard input are
// independent, which is what having two channels buys
const BOTH_SRC = `
(import (rnrs) (web args))
(define (read-all)
  (let loop ((acc '()))
    (let ((c (read-char)))
      (if (eof-object? c)
          (list->string (reverse acc))
          (loop (cons c acc))))))
(display (args-count))
(display "|")
(display (read-all))
`;

function build(name, source) {
    const src = path.join(dir, `${name}.ss`);
    const wasm = path.join(dir, `${name}.wasm`);
    const js = path.join(dir, `${name}.js`);
    fs.writeFileSync(src, source);
    execFileSync(path.join(root, 'bin/goeteiac'), [src, wasm],
                 { cwd: root, stdio: 'pipe' });
    execFileSync(path.join(root, 'bin/goeteiac'), ['--js', src, js],
                 { cwd: root, stdio: 'pipe' });
    return { wasm, js };
}

const echo = build('echo', ECHO_SRC);
const both = build('both', BOTH_SRC);

const INPUT = path.join(dir, 'input.txt');
fs.writeFileSync(INPUT, 'abc');

function run(runner, module_, rest) {
    return execFileSync(process.execPath,
                        [path.join(root, 'rt', runner), module_, ...rest],
                        { cwd: root, encoding: 'utf8' }).trim();
}

// every case is asserted on BOTH targets from one table
function both_targets(label, artifacts, rest, want) {
    require_(run('run.mjs', artifacts.wasm, rest) === want,
             `${label} (wasm)`,
             `wanted ${JSON.stringify(want)}, got ` +
             JSON.stringify(run('run.mjs', artifacts.wasm, rest)));
    require_(run('runjs.mjs', artifacts.js, rest) === want,
             `${label} (js)`,
             `wanted ${JSON.stringify(want)}, got ` +
             JSON.stringify(run('runjs.mjs', artifacts.js, rest)));
}

// the invocation every other test in the suite uses: unchanged
both_targets('no separator means no arguments', echo, [], '0');

// a separator with nothing after it is zero arguments, not one empty
both_targets('an empty tail is zero arguments', echo, ['--'], '0');

both_targets('three arguments arrive in order', echo,
             ['--', 'alpha', 'beta', 'gamma'],
             '3 [alpha] [beta] [gamma]');

// only the FIRST separator splits: a later one is the program's
both_targets('a later separator belongs to the program', echo,
             ['--', '--frames', '--', '2'],
             '3 [--frames] [--] [2]');

// one argument, spaces and all -- the shell already did the splitting
both_targets('an argument may contain spaces', echo,
             ['--', 'two words', 'x'],
             '2 [two words] [x]');

// a Goeteia string is UTF-8 bytes; a non-ASCII argument must cross
// unchanged rather than through a lossy decode
both_targets('a non-ASCII argument crosses unchanged', echo,
             ['--', 'é中文'],
             '1 [é中文]');

// the two channels do not interfere: input file AND arguments
both_targets('the input file still arrives with arguments given', both,
             [INPUT, '--', 'x', 'y'],
             '2|abc');

both_targets('the input file still arrives with no arguments', both,
             [INPUT],
             '0|abc');

// ...and arguments arrive with no input file
both_targets('arguments arrive with no input file', both,
             ['--', 'x'],
             '1|');

// ---- two programs in ONE process, started together ----
//
// The CLI cases above each get a fresh process.  A host that embeds
// the runner (a build script, a test harness, a server) starts
// modules in the same process and often at the same time, and each
// must still read ITS OWN argv.  A runner that published the list on
// the real global before its first await handed the earlier-started
// program the later one's arguments; sequential starts never showed
// it.  The wasm case starts the same bytes twice; the JS case starts
// two distinct files, because ESM caches a module per file and two
// starts of one file share one instance by construction.
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const echoJs2 = path.join(dir, 'echo2.js');
fs.copyFileSync(echo.js, echoJs2);
const echoWasm = fs.readFileSync(echo.wasm);

function pairs(label, got) {
    const want = ['1 [first]', '1 [second]'];
    require_(got[0] === want[0] && got[1] === want[1],
             `${label}: each program reads its own argv`,
             `wanted ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
}
{
    const rs = await Promise.all([runModule(echoWasm, [], ['first']),
                                  runModule(echoWasm, [], ['second'])]);
    pairs('two wasm programs started together (wasm)',
          rs.map(r => r.text.trim()));
}
{
    const rs = await Promise.all([runJsModule(echo.js, [], ['first']),
                                  runJsModule(echoJs2, [], ['second'])]);
    pairs('two js programs started together (js)',
          rs.map(r => r.text.trim()));
}
// a program that never got an argv still sees none, and one started
// after the pair is untouched by them
{
    const r = await runModule(echoWasm, [], []);
    require_(r.text.trim() === '0',
             'a program started with no argv reads none (wasm)',
             `got ${JSON.stringify(r.text.trim())}`);
}

// ---- the same JS file, one start after another ----
//
// ESM caches one module instance per file, so a runner that publishes
// only when it has something to publish leaves the previous start's
// list in place: a run with arguments followed by a run without reads
// the stale list.  The runner must publish on every start, an empty
// list included.
{
    await runJsModule(echo.js, [], ['stale']);
    const r = await runJsModule(echo.js, [], []);
    require_(r.text.trim() === '0',
             'a later start of the same js file with no argv reads none (js)',
             `got ${JSON.stringify(r.text.trim())}`);
}

// ---- artifacts without the seam ----
//
// A JS module emitted before `rt.global` existed has nowhere to
// publish to but the real global, and that is the bug; so the runner
// refuses -- only when there is an argument to publish, so an
// argv-less run of an old artifact is untouched.  The old shape is
// made from a current artifact by removing the export, which is
// exactly what an older compiler did not emit.
const SEAM = /,global:\(typeof GPROX!=='undefined'\?GPROX:void 0\)/;
{
    const cur = fs.readFileSync(echo.js, 'utf8');
    require_(SEAM.test(cur), 'the emitted module exports rt.global',
             'the seam regex matched nothing -- the export changed shape');
    const oldJs = path.join(dir, 'echo-old.js');
    fs.writeFileSync(oldJs, cur.replace(SEAM, ''));
    const r = await runJsModule(oldJs, [], []);
    require_(r.text.trim() === '0',
             'an old artifact still runs with no argv (js)',
             `got ${JSON.stringify(r.text.trim())}`);
    let threw = null;
    try { await runJsModule(oldJs, [], ['x']); } catch (e) { threw = e; }
    require_(threw && /rt\.global/.test(String(threw)),
             'an old artifact given argv is refused by name (js)',
             `got ${threw ? String(threw) : 'no error'}`);
}
// a module that reaches no JS kernel has no proxy at all: it must
// load and run, and be refused arguments the same way
{
    const plain = build('plain', '(import (rnrs)) (display 42)');
    const r = await runJsModule(plain.js, [], []);
    require_(r.text.trim() === '42',
             'a module without the JS kernel runs with no argv (js)',
             `got ${JSON.stringify(r.text.trim())}`);
    let threw = null;
    try { await runJsModule(plain.js, [], ['x']); } catch (e) { threw = e; }
    require_(threw && /rt\.global/.test(String(threw)),
             'a module without the JS kernel given argv is refused by name (js)',
             `got ${threw ? String(threw) : 'no error'}`);
}

if (!failed) console.log('args: ok');
process.exit(failed ? 1 : 0);
