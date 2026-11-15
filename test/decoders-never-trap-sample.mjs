// A malformed asset ends a decode in a condition that names the decoder,
// never in a trap or a timeout (ledger R98, batch M55): the sample of
// test/mutation-sample.tsv, decoded by the mutation harness of
// tools/mutate.mjs, each mutation alone in its own process.
//
// The sample (main's, from the census the code line took on 57868e4):
// for each driver, fixture, target and kind of trap in the batch's scope,
// the first, the middle and the last mutation that trapped -- 36
// mutations.  Three of them ran past 30 seconds on wasm (zstd's mb frame);
// a decode that does not finish in --timeout seconds is a failure like a
// trap.
//
// What a refusal may name: the decoder itself, and for KTX also zstd,
// which a supercompressed KTX file runs inside it.
//
// Four (driver, target) groups run at once (--jobs 4): one after another
// the sample takes about two minutes, close to the runner's limit for a
// cell when the machine is busy.
//
// ON THE TREE BEFORE THE CHANGE (57868e4) every one of the 36 traps or
// times out on at least one target.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const sampleFile = path.join(root, 'test', 'mutation-sample.tsv');
const out = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-sample-'));
process.on('exit', () => fs.rmSync(out, { recursive: true, force: true }));

const sample = fs.readFileSync(sampleFile, 'utf8').split('\n')
    .filter(l => l && !l.startsWith('#')).map(l => l.split('\t'));
const want = new Map();
for (const [driver, fixture] of sample) {
    const k = `${driver}/${fixture}`;
    want.set(k, (want.get(k) || 0) + 1);
}
const allowed = { ktx: ['ktx', 'zstd'], zstd: ['zstd'], uastc: ['uastc'],
                  image: ['image'], meshopt: ['meshopt'] };

const env = { ...process.env };
delete env.NODE_TEST_CONTEXT;
const r = spawnSync(process.execPath,
                    [path.join(root, 'tools', 'mutate.mjs'), '--sample', sampleFile,
                     '--out', out, '--timeout', '30', '--jobs', '4'],
                    { env, encoding: 'utf8', timeout: 1800000 });
assert.equal(r.status, 0, `the harness itself failed: ${(r.stderr || '').slice(-600)}`);
const summary = JSON.parse(fs.readFileSync(path.join(out, 'summary.json'), 'utf8'));

const failures = [];
const seen = new Map();
for (const e of summary) {
    for (const [fixture, v] of Object.entries(e.fixtures)) {
        const k = `${e.driver}/${fixture}`;
        if (!want.has(k)) continue;
        seen.set(`${k}/${e.target}`, v.mutations);
        if (v.mutations !== want.get(k))
            failures.push(`${k} ${e.target}: decoded ${v.mutations} of the sample's ${want.get(k)}`);
        if (v.trapped !== 0)
            failures.push(`${k} ${e.target}: ${v.trapped} trapped -- ${JSON.stringify(v.traps)}`);
        for (const who of Object.keys(v.refusedBy || {}))
            if (!allowed[e.driver].includes(who))
                failures.push(`${k} ${e.target}: a refusal names ${who}`);
    }
}
for (const k of want.keys())
    for (const t of ['wasm', 'js'])
        if (!seen.has(`${k}/${t}`)) failures.push(`${k} ${t}: not in the harness's summary`);

if (failures.length) {
    console.error(`FAIL ${failures.length}:`);
    for (const f of failures) console.error('  ' + f);
    process.exit(1);
}
console.log(`ok ${sample.length} mutations on both targets, none trapped`);
