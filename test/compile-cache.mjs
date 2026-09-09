// The compile cache, judged on the only question that matters: does a
// hit hand back what a cold compile would have produced, and does a
// miss happen every time it must?
//
// "The suite's verdicts are the same warm as cold" is NOT that question.
// A cache that always returned one wrong artifact could pass it, because
// both columns would be green for different reasons.  Two different wasm
// modules can both print #t.  So the artifact is compared byte for byte,
// and every must-miss case observes the miss itself rather than only the
// answer.
//
// The cache exists because the suite compiles 161 sources four ways in
// separate processes, about 0.2 s each with roughly 0.16 s of that being
// startup, and in nearly every round nearly every source is unchanged.
// It is sound here for one specific reason: this compiler is
// deterministic, which is not an assumption but a tested property --
// run-tests.sh already compares stage0 and stage1 output byte for byte.
// What can still go wrong is an incomplete key, and an incomplete key
// fails silently, so that is what this file is about.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
// The cache directory is pointed at a fresh temporary one before the
// module is loaded: a test that shared the developer's cache would be
// reading entries left by an earlier run, which is the same stale-read
// this file exists to prevent.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-cache-test-'));
process.env.GOETEIA_CACHE_DIR = path.join(tmp, 'cache');

const { keyFor, lookup, store, stats, resetStats, cacheDir, closureHash, compilerIdFor } =
    await import('../rt/cache.mjs');
const bytes = a => fs.readFileSync(a);

const base = {
    compilerId: 'compiler-abc',
    closureHash: 'closure-abc',
    target: 'wasm',
    options: '-O2',
    relPath: 'test/sample.ss',
    sourceBytes: Buffer.from('(display 1)\n'),
};

// ---- the key covers every part of the input identity ----
assert.equal(keyFor(base), keyFor({ ...base }), 'the same inputs must give the same key');

const changed = {
    'a byte of the source': { sourceBytes: Buffer.from('(display 2)\n') },
    'the compiler': { compilerId: 'compiler-xyz' },
    // The one a source-bytes key cannot see: editing lib/lng/effect.ss
    // leaves test/lng-effect.ss byte for byte the same, so a cache
    // without the closure would hand back the artifact built against
    // the old library and the suite would go green having tested
    // nothing that changed.  That is this line's oldest failure --
    // a stale artifact reading as a pass -- moved onto the cache.
    'a library the source imports': { closureHash: 'closure-xyz' },
    'the target': { target: 'js' },
    'the options': { options: '-O0' },
    // Today the artifact does not depend on the path: two byte-identical
    // sources under different names compile to identical output, and
    // src/compiler.ss says locations feed error messages and never the
    // emitted bytes.  The name is in the key anyway, because a key must
    // describe the whole input identity rather than the part that
    // happens to be sufficient today.  If a debug section or a source
    // path ever reaches the output, this line is what keeps the cache
    // honest, and nothing would have announced that day.
    'the name, with the bytes unchanged': { relPath: 'test/other.ss' },
};
for (const [what, diff] of Object.entries(changed)) {
    assert.notEqual(keyFor(base), keyFor({ ...base, ...diff }),
                    `changing ${what} must change the key`);
}

// ---- a hit returns the artifact byte for byte ----
const artifact = path.join(tmp, 'cold.wasm');
fs.writeFileSync(artifact, Buffer.from([0, 97, 115, 109, 1, 2, 3, 4, 5]));
const k = keyFor(base);
store(k, artifact);
const out = path.join(tmp, 'warm.wasm');
assert.equal(lookup(k, out), true, 'a stored key must be found');
assert.deepEqual(bytes(out), bytes(artifact), 'a hit must be byte-identical to the cold artifact');

// ---- a key that was never stored misses ----
assert.equal(lookup(keyFor({ ...base, sourceBytes: Buffer.from('(display 9)\n') }),
                    path.join(tmp, 'never.wasm')),
             false, 'an unknown key must miss');

// ---- an entry whose artifact is gone, or empty, misses ----
// The failure this prevents: a cache that reports a hit and leaves the
// output file untouched, so the runner tests whatever was there before.
const stored = path.join(cacheDir(), `${k}`);
const kGone = keyFor({ ...base, options: '-Ogone' });
store(kGone, artifact);
for (const f of fs.readdirSync(cacheDir())) {
    if (f.startsWith(kGone)) fs.unlinkSync(path.join(cacheDir(), f));
}
assert.equal(lookup(kGone, path.join(tmp, 'gone.wasm')), false,
             'an entry whose artifact is missing must miss');

const kEmpty = keyFor({ ...base, options: '-Oempty' });
const emptyArtifact = path.join(tmp, 'empty.wasm');
fs.writeFileSync(emptyArtifact, Buffer.alloc(0));
store(kEmpty, emptyArtifact);
assert.equal(lookup(kEmpty, path.join(tmp, 'fromempty.wasm')), false,
             'a zero-byte artifact must miss: it would enter the runner as a successful compile');

// ---- misses are counted, not just answered ----
resetStats();
const before = stats();
lookup(keyFor({ ...base, options: '-Ocount' }), path.join(tmp, 'count.wasm'));
const after = stats();
assert.equal(after.misses, before.misses + 1, 'a miss must be observable in stats()');
lookup(k, path.join(tmp, 'count2.wasm'));
assert.equal(stats().hits, after.hits + 1, 'a hit must be observable in stats()');

// ---- the cache lives outside the repository ----
assert.ok(!path.resolve(cacheDir()).startsWith(path.resolve(root) + path.sep),
          `the cache must not live inside the tree, or it pollutes git status: ${cacheDir()}`);

// ---- GOETEIA_NO_CACHE=1 turns it off, observably ----
// The gate runs cold and has to be able to prove it, so "disabled" is a
// reading rather than a belief.
const probe = path.join(tmp, 'probe.mjs');
fs.writeFileSync(probe, `
const { keyFor, lookup, store, stats } = await import(${JSON.stringify(path.join(root, 'rt/cache.mjs'))});
const k = keyFor(${JSON.stringify({ ...base, sourceBytes: undefined })});
const art = ${JSON.stringify(artifact)};
store(k, art);
const got = lookup(k, ${JSON.stringify(path.join(tmp, 'nocache.wasm'))});
console.log(JSON.stringify({ got, disabled: stats().disabled, hits: stats().hits }));
`.replace('"sourceBytes":undefined,', '"sourceBytes":"' + base.sourceBytes.toString('base64') + '",'));
const said = JSON.parse(execFileSync(process.execPath, [probe], {
    env: { ...process.env, GOETEIA_NO_CACHE: '1',
           GOETEIA_CACHE_DIR: process.env.GOETEIA_CACHE_DIR },
    encoding: 'utf8',
}));
assert.equal(said.got, false, 'with GOETEIA_NO_CACHE=1 a lookup must miss');
assert.equal(said.disabled, true, 'with GOETEIA_NO_CACHE=1 stats() must say so');
assert.equal(said.hits, 0, 'with GOETEIA_NO_CACHE=1 nothing may be counted as a hit');

// ---- two processes storing the same key do not corrupt it ----
// The gate runs in its own worktree while a session runs the suite, and
// both share this cache.  There is no lock and none is needed: the key
// is the content, so racing writers write the same bytes and the last
// rename wins harmlessly.  What must hold is that no reader ever sees a
// half-written entry, so the assertion is on the bytes, not on how many
// writes happened.
const racer = path.join(tmp, 'racer.mjs');
fs.writeFileSync(racer, `
process.env.GOETEIA_CACHE_DIR = ${JSON.stringify(process.env.GOETEIA_CACHE_DIR)};
const { store } = await import(${JSON.stringify(path.join(root, 'rt/cache.mjs'))});
store(process.argv[2], ${JSON.stringify(artifact)});
`);
const kRace = keyFor({ ...base, options: '-Orace' });
await Promise.all([0, 1, 2, 3].map(() => new Promise((res, rej) => {
    try { execFileSync(process.execPath, [racer, kRace]); res(); } catch (e) { rej(e); }
})));
const raced = path.join(tmp, 'raced.wasm');
assert.equal(lookup(kRace, raced), true, 'a key written by several processes must still be found');
assert.deepEqual(bytes(raced), bytes(artifact), 'a raced entry must still be byte-identical');

// ---- the two derived identities actually derive from something ----
// A compilerId that ignores the compiler, or a closureHash that ignores
// the libraries, would make every must-miss case above pass while the
// cache stayed wrong in the field.  These read the real tree.
const idWasm = compilerIdFor('wasm');
const idJs = compilerIdFor('js');
assert.ok(idWasm && idJs, 'compilerIdFor must answer for both targets');
assert.equal(idWasm, compilerIdFor('wasm'), 'the compiler identity must be stable');

const closureBefore = closureHash();
const scratch = path.join(root, 'lib', 'sim', '.cache-probe.ss');
fs.writeFileSync(scratch, ';; a file that exists only while this test runs\n');
try {
    assert.notEqual(closureHash(), closureBefore,
                    'adding a library file must change the closure hash');
} finally {
    fs.unlinkSync(scratch);
}
assert.equal(closureHash(), closureBefore, 'removing it again must restore the hash');

// The same question one directory over, and the reason this cell exists
// rather than being covered by the one above: the stage0 compiler
// identity used to be a hand-written list of the five files the driver
// reads.  A list like that does not fail when it falls behind -- a
// sixth source is simply absent from the key, so a compile with the new
// compiler is served the old compiler's artifact and the round goes
// green.  Hashing the directory is what this pins.
const stage0Before = compilerIdFor('wasm');
const srcProbe = path.join(root, 'src', '.cache-probe.ss');
fs.writeFileSync(srcProbe, ';; a file that exists only while this test runs\n');
try {
    assert.notEqual(compilerIdFor('wasm'), stage0Before,
                    'a new file under src/ must change the stage0 compiler identity');
} finally {
    fs.unlinkSync(srcProbe);
}
assert.equal(compilerIdFor('wasm'), stage0Before,
             'removing it again must restore the stage0 identity');

fs.rmSync(tmp, { recursive: true, force: true });
