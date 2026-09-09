// Copyright 2026 guenchi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// A content-addressed cache for compiled test artifacts.
//
// The suite compiles every source in its own process, and nearly every
// source is unchanged from the round before.  This is sound here for
// one specific reason: the compiler is deterministic for a fixed
// (compiler, source, target, options), which is not an assumption but a
// property run-tests.sh already checks -- it compares stage0 and stage1
// output byte for byte on every test.
//
// WHAT CAN STILL GO WRONG IS AN INCOMPLETE KEY, and it fails silently:
// a hit that should have been a miss hands back an artifact built from
// something else, the suite runs it, and the result is green while
// testing nothing.  That is the oldest failure in this tree wearing a
// new coat.  So the key is the whole contract, and every field of it is
// here rather than at the call sites:
//
//   compiler identity -- whichever compiler produces this target
//   closure hash      -- every library the compile could read
//   target, options   -- what was asked for
//   relative path     -- the file's identity, not where it sits today
//   source bytes      -- the file itself
//
// The closure is the one a caller is most likely to forget: editing
// lib/lng/effect.ss changes not one byte of test/lng-effect.ss, so a
// key without it hits, and the suite validates a new library with an
// old artifact.  The cost of including it is that any library edit
// empties the cache, which is correct: every test that imports it does
// have to be recompiled.
//
// The cache is an optimisation for the person iterating.  The gate runs
// with GOETEIA_NO_CACHE=1 and always compiles from source, because a
// result that was never produced from the source is not evidence.
//
// NOT WIRED INTO THE SUITE, and the reason is a measurement rather than
// an oversight.  run-tests.sh is a shell script that compiles each
// source in its own process, so using this from there costs a node
// startup per compile -- about 50 ms against a compile of 130-220 ms.
// A hit would then save 80-120 ms and a miss would LOSE 50-100 ms; and
// since a cache only pays across rounds, while the closure hash is
// busted by any edit under lib/ -- which is usually why a round is
// being run -- the case that actually benefits is "only a test
// changed", which the gate never takes because it runs cold by policy.
// The remaining benefit was narrower than the risk of putting a thing
// that can silently return the wrong artifact on the path everything
// else is judged by.
//
// What would change that: a driver that starts node ONCE for the whole
// suite.  Called in-process, the 50 ms startup disappears and every hit
// is a clean saving.  The module is finished and tested for that day;
// it is the wiring, not the cache, that is missing.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Read once, at load: the gate sets it for the whole run, and a value
// that could change mid-run would make `stats()` describe nothing.
const disabled = process.env.GOETEIA_NO_CACHE === '1';

let hits = 0, misses = 0, stores = 0;

export function stats() {
    return { hits, misses, stores, disabled };
}

// Assertions are per-case; without this the counts from one case leak
// into the next and every assertion after the first is about a total.
export function resetStats() {
    hits = 0; misses = 0; stores = 0;
}

// Outside the repository, always.  Inside it, the entries would show up
// in `git status` and in the per-file digests a session takes before a
// suite run to prove nobody touched the tree -- and that measurement is
// worth more than this cache.
export function cacheDir() {
    return process.env.GOETEIA_CACHE_DIR
        || path.join(os.tmpdir(), 'goeteia-compile-cache');
}

function sha256(...parts) {
    const h = crypto.createHash('sha256');
    for (const p of parts) h.update(p);
    return h.digest('hex');
}

// Every field is length-prefixed before hashing.  Concatenating them
// raw lets two different inputs produce one key -- target "a" with
// options "bc" and target "ab" with options "c" -- and a key collision
// here is exactly the silent wrong artifact this file is about.
function field(v) {
    const b = v === undefined || v === null
        ? Buffer.alloc(0)
        : (Buffer.isBuffer(v) ? v : Buffer.from(String(v), 'utf8'));
    const len = Buffer.alloc(8);
    len.writeBigUInt64BE(BigInt(b.length));
    return [len, b];
}

export function keyFor({ compilerId, closureHash, target, options, relPath, sourceBytes }) {
    return sha256(...field(compilerId), ...field(closureHash), ...field(target),
                  ...field(options), ...field(relPath), ...field(sourceBytes));
}

function hashTree(files) {
    const h = crypto.createHash('sha256');
    // Sorted by path, and the PATH IS HASHED TOO: a rename that leaves
    // the bytes alone still changes the tree, and a cache that could
    // not see that would serve one file's entry for another's.
    for (const rel of files.slice().sort()) {
        const abs = path.join(root, rel);
        let body;
        try { body = fs.readFileSync(abs); } catch { continue; }
        for (const p of field(rel)) h.update(p);
        for (const p of field(body)) h.update(p);
    }
    return h.digest('hex');
}

function walk(dir, out) {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
    for (const e of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
        const abs = path.join(dir, e.name);
        if (e.isDirectory()) walk(abs, out);
        else if (e.name.endsWith('.ss')) out.push(path.relative(root, abs));
    }
    return out;
}

// Every library a compile could read.  test/lib/** is in it because
// tests import each other through it, and leaving it out would be the
// same hole one directory over.
//
// Computed fresh on every call rather than memoised: a caller that
// changes a library and asks again must be told, and the runner calls
// it once per suite run anyway.
export function closureHash() {
    return hashTree([...walk(path.join(root, 'lib'), []),
                     ...walk(path.join(root, 'test', 'lib'), [])]);
}

// Which compiler produces this target.  stage0 reads the same sources
// whichever target it emits -- the target is a separate field of the
// key, so it does not need to be folded in here as well.
//
// The whole of src/ is hashed rather than a list of the files the
// driver is known to read.  A list has to be maintained by whoever adds
// a source, and a list that falls behind does not fail: it produces a
// key that ignores the new file, so a compile with the new compiler
// serves the old compiler's artifact and the round goes green.  Nothing
// in this file, and nothing in the suite, would say a word about it.
// Hashing the directory costs one extra read per entry today -- src/
// holds five files -- and removes the entire class.
export function compilerIdFor(target) {
    if (target === 'stage1') return hashTree(['goeteia.wasm', 'rt/compile.mjs']);
    return hashTree(walk(path.join(root, 'src'), []));
}

function entryPath(key) {
    return path.join(cacheDir(), key);
}

// A hit has to survive three questions, not one: is there an entry, is
// the artifact still there, and is it non-empty.  A zero-byte artifact
// would go on to be run as if the compile had succeeded, and fail later
// with something that says nothing about where it came from.
export function lookup(key, outFile) {
    if (disabled) { misses++; return false; }
    const p = entryPath(key);
    let st;
    try { st = fs.statSync(p); } catch { misses++; return false; }
    if (!st.isFile() || st.size === 0) { misses++; return false; }
    try {
        fs.mkdirSync(path.dirname(outFile), { recursive: true });
        fs.copyFileSync(p, outFile);
    } catch { misses++; return false; }
    hits++;
    return true;
}

// Nothing is stored for a compile that did not produce an artifact, so
// a failure cannot be inherited by the next run of the same source.
// The write goes to a temporary name and is renamed into place, which
// is atomic on one filesystem: two processes racing to store one key
// write the same bytes -- the key is the content -- so the loser's
// rename is harmless and no reader ever sees a half-written entry.
export function store(key, outFile) {
    if (disabled) return;
    let st;
    try { st = fs.statSync(outFile); } catch { return; }
    if (!st.isFile() || st.size === 0) return;
    const dir = cacheDir();
    fs.mkdirSync(dir, { recursive: true });
    const tmp = path.join(dir, `.tmp-${process.pid}-${Math.random().toString(36).slice(2)}`);
    try {
        fs.copyFileSync(outFile, tmp);
        fs.renameSync(tmp, entryPath(key));
        stores++;
    } catch {
        try { fs.unlinkSync(tmp); } catch { /* the entry simply is not created */ }
    }
}
