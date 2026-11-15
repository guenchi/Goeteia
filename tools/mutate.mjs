// The mutation harness of ledger R98 (batch M55): every decoder of
// (gfx ...) is handed its fixtures with each byte changed and each
// eight-byte run filled, one mutation at a time, and each outcome is
// classified decoded, refused (a condition, with its who and message) or
// trapped (anything that ends the program instead: a wasm trap, a host
// error on JS, a killed process, or no progress for the timeout).
//
//   node tools/mutate.mjs [--drivers ktx,zstd,...] [--targets wasm,js]
//                         [--chunk 200] [--jobs 2] [--timeout 30]
//                         [--chunk-timeout 120] [--out DIR]
//   node tools/mutate.mjs --sample FILE [--targets ...] [--timeout 30]
//                         [--out DIR]
//
// The drivers are tools/mutation/<name>.ss; tools/mutation/harness.ss,
// appended to each, numbers the mutations and decodes a range of them
// (its header says how).  Each driver is compiled once per target by the
// tree's own compiler (rt/compile.mjs), as test/decoders-never-trap.mjs
// does.
//
// One process decodes a chunk of mutations in order.  A trap ends it
// between the "try" line of a mutation and its "out" line; the tool
// records that mutation as trapped and starts a new process at the next
// one.  Mutations that share a process share its memory, so after the
// walk every trapped mutation is decoded again alone, and both readings
// are reported: a trap that does not recur alone is a state the earlier
// mutations left, and is listed as such.
//
// rt/run.mjs and rt/runjs.mjs hold a program's output until it ends, and
// write it then -- with the error, when it traps -- so the lines of a
// process are read after it exits.  A process that is killed (a chunk
// that runs past --chunk-timeout seconds, or one the system kills) leaves
// none; its chunk is then decoded again one mutation per process, each
// with --timeout seconds, and a mutation that runs past that alone is
// classified a timeout.  The children write to files, not pipes: a pipe
// on macOS is written asynchronously.
//
// --sample FILE decodes only the mutations FILE lists, one a line as
// "driver fixture len pos val" (tab- or space-separated, anything after
// the fifth field ignored, lines starting with # skipped), each alone in
// its own process with --timeout seconds: the driver takes it by that
// spec (MUTANT_SPEC), so a sample does not depend on the numbering.  The
// summary then counts, per fixture, the sample's mutations only.
//
// Output, in DIR (default mutate-out/): <driver>-<target>.tsv, one line
// per mutation (number, fixture, len, pos, val, outcome, detail);
// summary.json; and a table on stdout -- per driver, fixture and target,
// the counts decoded, refused and trapped, the traps by class.

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const ALL = ['ktx', 'zstd', 'uastc', 'meshopt', 'image', 'gltf'];

const opts = { drivers: ALL, targets: ['wasm', 'js'], chunk: 200, jobs: 2,
               timeout: 30, 'chunk-timeout': 120, out: 'mutate-out', sample: '' };
for (let i = 2; i < process.argv.length; i += 2) {
    const k = process.argv[i].replace(/^--/, '');
    const v = process.argv[i + 1];
    if (!(k in opts) || v === undefined) {
        console.error(`unknown or incomplete option ${process.argv[i]}`);
        process.exit(2);
    }
    opts[k] = Array.isArray(opts[k]) ? v.split(',') : (typeof opts[k] === 'number' ? Number(v) : v);
}
for (const d of opts.drivers) {
    if (!ALL.includes(d)) { console.error(`no driver ${d}`); process.exit(2); }
}
fs.mkdirSync(opts.out, { recursive: true });

const { compileSource } = await import('../rt/compile.mjs');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-mutate-'));
process.on('exit', () => fs.rmSync(work, { recursive: true, force: true }));
const harness = fs.readFileSync(path.join(root, 'tools', 'mutation', 'harness.ss'), 'utf8');

async function build(d, t) {
    const src = fs.readFileSync(path.join(root, 'tools', 'mutation', d + '.ss'), 'utf8')
          + '\n' + harness;
    const bytes = await compileSource(src, t === 'js' ? { baseDir: root, target: 'js' }
                                                      : { baseDir: root });
    const file = path.join(work, `${d}.${t === 'js' ? 'mjs' : 'wasm'}`);
    fs.writeFileSync(file, bytes);
    return file;
}

// Runs the program on the mutations [from, to); resolves with the lines
// it printed, how it ended, and the last lines of its stderr.
function run(t, file, from, to, spec = '') {
    return new Promise((resolve) => {
        const tag = `${path.basename(file)}-${from}-${to}-${process.hrtime.bigint()}`;
        const outF = path.join(work, tag + '.out');
        const errF = path.join(work, tag + '.err');
        const fo = fs.openSync(outF, 'w');
        const fe = fs.openSync(errF, 'w');
        const runner = path.join(root, 'rt', t === 'js' ? 'runjs.mjs' : 'run.mjs');
        const child = spawn(process.execPath, [runner, file], {
            stdio: ['ignore', fo, fe],
            env: { ...process.env, MUTANT_FROM: String(from), MUTANT_TO: String(to),
                   MUTANT_SPEC: spec },
        });
        // the wall-clock limit: one mutation alone, or a chunk
        const limit = (to - from === 1 || from === -3 ? opts.timeout : opts['chunk-timeout']) * 1000;
        let timedOut = false;
        const watch = setTimeout(() => { timedOut = true; child.kill('SIGKILL'); }, limit);
        child.on('exit', (code, signal) => {
            clearTimeout(watch);
            fs.closeSync(fo); fs.closeSync(fe);
            const lines = fs.readFileSync(outF, 'utf8').split('\n').filter(Boolean);
            const err = fs.readFileSync(errF, 'utf8').split('\n').filter(Boolean);
            fs.rmSync(outF); fs.rmSync(errF);
            resolve({ lines, code, signal, timedOut, err });
        });
    });
}

// the class of an ending that is not a normal exit
function trapClass(r) {
    if (r.timedOut) return `timeout (${opts.timeout} s alone)`;
    const m = r.err.map((l) => l.match(/\b((?:Runtime|Type|Range|Reference|Syntax|Compile|Link)?Error): (.*)$/))
          .find(Boolean);
    if (m) {
        // the message, without the parts that name a particular value
        return `${m[1]}: ${m[2].replace(/'[^']*'/g, "'_'").replace(/\d+/g, 'N').slice(0, 100)}`;
    }
    if (r.signal) return `killed by ${r.signal}`;
    return `exit ${r.code}: ${(r.err.at(-1) || '').slice(0, 100)}`;
}

// (try k name len pos val) and (out k decoded) / (out k refused who "msg")
const TRY = /^\(try (\d+) (\S+) (\d+) (\d+) (\d+)\)$/;
const OUT = /^\(out (\d+) (decoded|refused)(?: (\S+) (".*"))?\)$/;

async function controlled(d, t) {
    const file = await build(d, t);
    const ctl = await run(t, file, -2, 0);
    const bad = ctl.lines.filter((l) => l.startsWith('(control ') && !l.endsWith(' decoded)'));
    if (ctl.code !== 0 || bad.length || !ctl.lines.some((l) => l.startsWith('(control '))) {
        throw new Error(`${d}/${t}: a fixture does not decode unchanged: `
                        + `${bad.join(' | ') || trapClass(ctl)}`);
    }
    return file;
}

function summarize(d, t, rows, counts) {
    const lines = rows.map((x) => [x.k, x.name, x.len, x.pos, x.val, x.outcome, x.detail,
                                   x.alone === undefined ? '' : `alone: ${x.alone}`].join('\t'));
    fs.writeFileSync(path.join(opts.out, `${d}-${t}.tsv`), lines.join('\n') + '\n');
    const by = {};
    for (const c of counts) {
        by[c.name] = { bytes: c.bytes, mutations: c.mutations, decoded: 0, refused: 0,
                       trapped: 0, traps: {}, refusedBy: {}, notAlone: 0 };
    }
    for (const x of rows) {
        const b = by[x.name];
        b[x.outcome] += 1;
        if (x.outcome === 'trapped') {
            b.traps[x.detail] = (b.traps[x.detail] || 0) + 1;
            if (x.alone === 'decoded' || x.alone === 'refused') b.notAlone += 1;
        } else if (x.outcome === 'refused') {
            const who = x.detail.split(' ')[0];
            b.refusedBy[who] = (b.refusedBy[who] || 0) + 1;
        }
    }
    return { driver: d, target: t, total: rows.length, fixtures: by };
}

// the --sample mode: each listed mutation alone, by its spec
async function sampled(d, t, items) {
    const file = await controlled(d, t);
    const rows = [];
    for (const [k, it] of items.entries()) {
        const spec = `${it.name} ${it.len} ${it.pos} ${it.val}`;
        const r = await run(t, file, -3, 0, spec);
        if (r.lines.some((l) => l.startsWith('(no-fixture '))) {
            throw new Error(`${d}/${t}: the driver has no fixture ${it.name}`);
        }
        const out = r.lines.map((l) => l.match(OUT)).find(Boolean);
        rows.push(out ? { k, ...it, outcome: out[2],
                          detail: out[2] === 'refused' ? `${out[3]} ${JSON.parse(out[4])}` : '' }
                      : { k, ...it, outcome: 'trapped', detail: trapClass(r) });
    }
    const counts = [...new Set(items.map((x) => x.name))]
          .map((name) => ({ name, bytes: null, mutations: items.filter((x) => x.name === name).length }));
    return summarize(d, t, rows, counts);
}

async function walk(d, t) {
    const file = await controlled(d, t);
    const census = await run(t, file, -1, 0);
    const counts = census.lines.map((l) => l.match(/^\(count (\S+) (\d+) (\d+)\)$/)).filter(Boolean)
          .map((m) => ({ name: m[1], bytes: +m[2], mutations: +m[3] }));
    const total = +(census.lines.find((l) => l.startsWith('(total ')) || '(total -1)').slice(7, -1);
    if (census.code !== 0 || total < 0) {
        throw new Error(`${d}/${t}: the census did not run: ${census.err.slice(-3).join(' | ')}`);
    }
    // every mutation's identity, from the census
    const ids = [];
    for (const l of census.lines) {
        const m = l.match(/^\(m (\d+) (\S+) (\d+) (\d+) (\d+)\)$/);
        if (m) ids[+m[1]] = { k: +m[1], name: m[2], len: +m[3], pos: +m[4], val: +m[5] };
    }
    if (ids.length !== total || ids.some((x) => !x)) {
        throw new Error(`${d}/${t}: the census listed ${ids.filter(Boolean).length} of ${total} mutations`);
    }
    const rows = new Array(total);
    let k = 0;
    while (k < total) {
        const to = Math.min(k + opts.chunk, total);
        const r = await run(t, file, k, to);
        let last = null;
        for (const l of r.lines) {
            let m;
            if ((m = l.match(TRY))) {
                last = { k: +m[1], name: m[2], len: +m[3], pos: +m[4], val: +m[5] };
            } else if ((m = l.match(OUT)) && last && +m[1] === last.k) {
                rows[last.k] = { ...last, outcome: m[2],
                                 detail: m[2] === 'refused' ? `${m[3]} ${JSON.parse(m[4])}` : '' };
                last = null;
            }
        }
        if (last && !r.timedOut) {
            rows[last.k] = { ...last, outcome: 'trapped', detail: trapClass(r) };
            k = last.k + 1;
        } else if (r.code === 0 && rows[to - 1]) {
            k = to;
        } else {
            // killed, or no line to say which mutation was in flight: the
            // rest of the chunk one mutation per process
            for (let j = k; j < to; j++) {
                if (rows[j]) continue;
                const a = await run(t, file, j, j + 1);
                const out = a.lines.map((l) => l.match(OUT)).find(Boolean);
                const at = ids[j];
                rows[j] = out ? { ...at, outcome: out[2],
                                  detail: out[2] === 'refused' ? `${out[3]} ${JSON.parse(out[4])}` : '' }
                              : { ...at, outcome: 'trapped', detail: trapClass(a) };
            }
            k = to;
        }
    }
    // every trap again, alone
    for (const row of rows.filter((x) => x.outcome === 'trapped')) {
        const r = await run(t, file, row.k, row.k + 1);
        const out = r.lines.map((l) => l.match(OUT)).find(Boolean);
        row.alone = out ? out[2] : trapClass(r);
    }
    return summarize(d, t, rows, counts);
}

const jobs = [];
const sample = {};
if (opts.sample) {
    for (const l of fs.readFileSync(opts.sample, 'utf8').split('\n')) {
        if (!l.trim() || l.startsWith('#')) continue;
        const [d, name, len, pos, val] = l.trim().split(/\s+/);
        if (!ALL.includes(d) || [len, pos, val].some((x) => !/^\d+$/.test(x || ''))) {
            console.error(`${opts.sample}: not a mutation: ${l}`);
            process.exit(2);
        }
        (sample[d] ||= []).push({ name, len: +len, pos: +pos, val: +val });
    }
    for (const d of Object.keys(sample)) for (const t of opts.targets) jobs.push([d, t]);
} else {
    for (const d of opts.drivers) for (const t of opts.targets) jobs.push([d, t]);
}
const results = [];
let next = 0;
async function worker() {
    while (next < jobs.length) {
        const [d, t] = jobs[next++];
        const t0 = Date.now();
        const r = opts.sample ? await sampled(d, t, sample[d]) : await walk(d, t);
        r.seconds = Math.round((Date.now() - t0) / 1000);
        results.push(r);
        console.error(`${d}/${t}: ${r.total} mutations in ${r.seconds} s`);
    }
}
await Promise.all(Array.from({ length: Math.max(1, opts.jobs) }, worker));

results.sort((a, b) => jobs.findIndex(([d, t]) => d === a.driver && t === a.target)
                       - jobs.findIndex(([d, t]) => d === b.driver && t === b.target));
fs.writeFileSync(path.join(opts.out, 'summary.json'), JSON.stringify(results, null, 1) + '\n');
console.log('| driver | fixture | target | mutations | decoded | refused | trapped | traps by class |');
console.log('|---|---|---|---|---|---|---|---|');
for (const r of results) {
    for (const [name, b] of Object.entries(r.fixtures)) {
        const traps = Object.entries(b.traps).map(([c, n]) => `${n} ${c}`).join('; ')
              + (b.notAlone ? ` (${b.notAlone} not trapping alone)` : '');
        console.log(`| ${r.driver} | ${name} | ${r.target} | ${b.mutations} | ${b.decoded} | `
                    + `${b.refused} | ${b.trapped} | ${traps} |`);
    }
}
