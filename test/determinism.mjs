// Numeric determinism harness.
//
// test/determinism-battery.ss is a fixed list of computations whose
// every result is printed as an IEEE 754 bit pattern.  This runs that
// battery through six independent channels --
//
//   stage0 -> wasm       the Chez-hosted compiler, run on WebAssembly
//   stage1 -> wasm       the self-hosted compiler, same target
//   stage1 -> wasm, -O0  the same, with the optimization passes off
//   stage0 -> JS         the Chez-hosted compiler, run as an ES module
//   stage1 -> JS         the self-hosted compiler, same target
//   stage1 -> JS, -O0    the same, with the optimization passes off
//
// -- three times each, and requires all eighteen outputs to be equal
// byte for byte.  Three runs per channel rule out a hidden
// nondeterministic source (iteration order, uninitialised memory,
// address-dependent results); the channels rule out one backend, one
// compiler host or the optimizer drifting from the others.  This is
// degeneracy in the strict sense: the wasm and the JS paths share no
// arithmetic code, so a defect would have to occur twice,
// identically, to pass unnoticed.
//
// Comparison is exact.  There is no tolerance to widen: two runs of
// the same program either produce the same bits or the determinism
// contract in docs/determinism.md is broken, and every golden test in
// the tree rests on that contract.
//
// Copyright (c) 2026 guenchi.  MIT license; see LICENSE.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const battery = path.join(here, 'determinism-battery.ss');
const VERBOSE_INPUT = [0x76];           // "v": the full value list
const RUNS = 3;

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-determinism-'));

// Nothing here throws on a finding: one divergence must not hide the
// others, since a determinism audit is only worth as much as the list
// it comes back with.
let failed = false;
function require_(cond, message, detail) {
    if (cond) return;
    failed = true;
    console.error(`determinism: ${message}`);
    if (detail) console.error(detail);
}

function stage0(outFile, extra = []) {
    execFileSync(path.join(root, 'bin/goeteiac'),
                 [...extra, battery, outFile],
                 { stdio: ['ignore', 'pipe', 'pipe'] });
    return fs.readFileSync(outFile);
}

// ---- the six channels --------------------------------------------
// bin/goeteiac runs the optimization passes; `script: true` is the
// -O0 spelling, so the last pair also asks whether the optimizer
// preserves the arithmetic it rewrites.
const s0Wasm = stage0(path.join(dir, 's0.wasm'));
const s0Js = stage0(path.join(dir, 's0.js'), ['--js']);
const s1Wasm = await compileToBytes(battery, {});
const s1Js = await compileToBytes(battery, { target: 'js' });
const s1Wasm0 = await compileToBytes(battery, { script: true });
const s1Js0 = await compileToBytes(battery, { script: true, target: 'js' });

// The emitted artifact itself is part of the contract: the same source
// through two compiler hosts has to produce the same bytes, or the two
// hosts are not running the same program and comparing their output
// proves nothing about the backends.
require_(Buffer.from(s0Wasm).equals(Buffer.from(s1Wasm)),
         'stage0 and stage1 emit different wasm for the battery '
         + `(${s0Wasm.length} vs ${s1Wasm.length} bytes)`);
require_(s0Js.toString() === Buffer.from(s1Js).toString(),
         'stage0 and stage1 emit different JS for the battery');

// ---- run each channel RUNS times ---------------------------------
// Each JS run imports a distinct file: the ES module cache is keyed by
// URL, so re-importing one path would replay a single instantiation
// instead of a fresh one.
async function wasmRuns(label, bytes) {
    const outs = [];
    for (let i = 0; i < RUNS; i++) {
        outs.push((await runModule(bytes, VERBOSE_INPUT)).text);
    }
    return { label, outs };
}

async function jsRuns(label, text) {
    const outs = [];
    for (let i = 0; i < RUNS; i++) {
        const file = path.join(dir, `${label}-${i}.mjs`);
        fs.writeFileSync(file, text);
        outs.push((await runJsModule(file, VERBOSE_INPUT)).text);
    }
    return { label, outs };
}

const channels = [
    await wasmRuns('stage0-wasm', s0Wasm),
    await wasmRuns('stage1-wasm', s1Wasm),
    await wasmRuns('stage1-wasm-O0', s1Wasm0),
    await jsRuns('stage0-js', Buffer.from(s0Js).toString()),
    await jsRuns('stage1-js', Buffer.from(s1Js).toString()),
    await jsRuns('stage1-js-O0', Buffer.from(s1Js0).toString()),
];

// ---- reporting ---------------------------------------------------
// The battery marks each section with "=== <name> <digest> n=<bytes>",
// so a mismatched line can be named rather than merely numbered.
function sectionOf(lines, index) {
    for (let i = index; i < lines.length; i++) {
        if (lines[i].startsWith('=== ')) {
            return `section ${lines[i].split(' ')[1]}`;
        }
    }
    return 'the digest line';
}

function describe(aLabel, a, bLabel, b) {
    const la = a.split('\n');
    const lb = b.split('\n');
    const report = [];
    if (la.length !== lb.length) {
        report.push(`  line count: ${aLabel} ${la.length}, ${bLabel} ${lb.length}`);
    }
    const perSection = new Map();
    let first = null;
    for (let i = 0; i < Math.max(la.length, lb.length); i++) {
        if (la[i] === lb[i]) continue;
        const s = sectionOf(la, i);
        perSection.set(s, (perSection.get(s) ?? 0) + 1);
        if (first === null) {
            first = `  first difference at line ${i + 1}, ${s}:\n` +
                    `    ${aLabel}: ${la[i]}\n    ${bLabel}: ${lb[i]}`;
        }
    }
    if (first) report.push(first);
    for (const [s, n] of perSection) {
        report.push(`  ${s}: ${n} differing line(s)`);
    }
    return report.join('\n');
}

// 1. each channel repeats itself
for (const { label, outs } of channels) {
    for (let i = 1; i < outs.length; i++) {
        require_(outs[i] === outs[0],
                 `${label} is not reproducible: run ${i + 1} differs from run 1`,
                 describe(`${label}#1`, outs[0], `${label}#${i + 1}`, outs[i]));
    }
}

// 2. every channel agrees with every other
const ref = channels[0];
for (const ch of channels.slice(1)) {
    require_(ch.outs[0] === ref.outs[0],
             `${ch.label} disagrees with ${ref.label}`,
             describe(ref.label, ref.outs[0], ch.label, ch.outs[0]));
}

// 3. the battery's own oracle line, which run-tests.sh checks, has to
//    be the last line of the verbose output too -- a section digest
//    that stopped being printed would silently shrink the coverage
for (const ch of channels) {
    const lines = ch.outs[0].trimEnd().split('\n');
    const summary = lines[lines.length - 1];
    require_(/^trig .*bigfl /.test(summary),
             `${ch.label}: the digest line lost sections: ${summary}`);
}

if (!failed) {
    const lines = ref.outs[0].trimEnd().split('\n');
    console.log(`determinism: ${channels.length} channels x ${RUNS} runs, ` +
                `${lines.length} lines identical`);
    console.log(`determinism: ${lines[lines.length - 1]}`);
}

fs.rmSync(dir, { recursive: true, force: true });
process.exit(failed ? 1 : 0);
