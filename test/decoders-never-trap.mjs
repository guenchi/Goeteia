// A malformed asset ends a decode in a condition, never in a trap (ledger
// R98, batch M55).
//
// test/mutation/ktx.ss and test/mutation/zstd.ss decode one mutation of a
// bundled fixture, named by the environment variable MUTANT, and print
// "decoded" or "refused: <message>".  A trap -- an illegal cast, a memory
// or array access out of bounds, an array too large on wasm; a host error
// on JS -- ends the process, so each mutation runs in a process of its own.
// Each driver is compiled once per target.
//
// The mutations are a fixed sample of the ones that trapped when every byte
// of the fixtures was changed (the code line's harness during batch M50,
// archived with that batch): for each kind of mutation and each kind of
// trap, the first, the middle and the last that the harness found.  Every
// one of them was read trapping on master 6bdfbbd, on wasm, before this
// batch.  A mutation may decode -- into whatever the changed bytes mean --
// or be refused; what it may not do is stop the program.  A decode that
// does not finish in 30 seconds is a failure too: a malformed count must
// not turn into an endless loop either.
//
// The controls: the unchanged fixtures decode, and the over-subscribed
// Huffman lengths of batch M50 are refused.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const { compileSource } = await import('../rt/compile.mjs');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-mutation-'));
process.on('exit', () => fs.rmSync(tmp, { recursive: true, force: true }));

const env = { ...process.env };
delete env.NODE_TEST_CONTEXT;

// len pos val for ktx (len 1: one byte, len 8: a run); frame pos val for
// zstd (frame 0: the text, 1: the blob)
const trapped = {
    'ktx': [
        '1 280 0', '1 548 0', '1 575 1',
        '1 23 255', '1 65 0', '1 439 0',
        '1 22 255', '1 26 128', '1 27 64',
        '1 23 127', '1 23 64',
        '8 395 255', '8 523 254', '8 568 223',
        '8 16 255', '8 18 239', '8 20 223',
        '8 15 255', '8 15 239', '8 15 223',
    ],
    'zstd': ['0 9 128', '1 9 64', '1 3081 64'],
};
const controls = [
    ['ktx', '1 0 171', /^decoded$/],
    ['ktx', '1 525 255', /^refused: over-subscribed huffman code lengths$/],
    ['zstd', '0 0 40', /^decoded$/],
];

const built = {};
for (const t of ['wasm', 'js']) {
    for (const d of ['ktx', 'zstd']) {
        const src = fs.readFileSync(path.join(root, 'test', 'mutation', d + '.ss'), 'utf8');
        const out = path.join(tmp, `${d}.${t === 'js' ? 'mjs' : 'wasm'}`);
        const bytes = await compileSource(src,
            t === 'js' ? { baseDir: root, target: 'js' } : { baseDir: root });
        fs.writeFileSync(out, bytes);
        built[`${d}/${t}`] = out;
    }
}

function decode(t, d, spec) {
    const runner = path.join(root, 'rt', t === 'js' ? 'runjs.mjs' : 'run.mjs');
    const r = spawnSync(process.execPath, [runner, built[`${d}/${t}`]],
                        { env: { ...env, MUTANT: spec }, encoding: 'utf8', timeout: 30000 });
    const out = (r.stdout || '').trim().split('\n').pop() || '';
    const err = (r.stderr || '').trim().split('\n').slice(-1)[0] || '';
    if (r.error && r.error.code === 'ETIMEDOUT') return { ok: false, what: 'did not finish in 30 s' };
    if (r.status !== 0) return { ok: false, what: `exit ${r.status}: ${err.slice(0, 160)}` };
    return { ok: /^(decoded|refused)/.test(out), what: out };
}

const failures = [];
let cases = 0;
for (const t of ['wasm', 'js']) {
    for (const [d, spec, want] of controls) {
        cases++;
        const r = decode(t, d, spec);
        if (!want.test(r.what)) failures.push(`control ${d} [${spec}] ${t}: ${r.what}`);
    }
    for (const d of Object.keys(trapped)) {
        for (const spec of trapped[d]) {
            cases++;
            const r = decode(t, d, spec);
            if (!r.ok) failures.push(`${d} [${spec}] ${t}: ${r.what}`);
        }
    }
}

if (failures.length) {
    console.error(`FAIL ${failures.length} of ${cases}:`);
    for (const f of failures) console.error('  ' + f);
    process.exit(1);
}
console.log(`ok ${cases} decodes, none trapped`);
assert.ok(cases > 0);
