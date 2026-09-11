// The compiler's own sources define no top-level name twice.  The Chez
// host lets a later define win silently, so every stage0 reading stays
// green over a duplicate; the self-hosted compiler refuses "defined
// twice", so the snapshot cannot be rebuilt from such a source and the
// tree cannot build itself -- which is how a second (define
// *lib-origins* ...) reached a commit.  A rebuild reports the symptom
// at the end of a minute's work; this scan names the name and the
// file in a second, before the commit.  It reads only top-level
// (define name ...) and (define (name ...) ...) forms at column zero,
// which is how these files are written.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sources = ['src/compiler.ss', 'src/js-backend.ss', 'src/wasm-driver.ss', 'src/chez-driver.ss', 'src/prelude.ss'];

for (const file of sources) {
    test(`${file} defines no top-level name twice`, () => {
        const text = fs.readFileSync(path.join(root, file), 'utf8');
        const seen = new Map();
        const dups = [];
        let line = 0;
        for (const l of text.split('\n')) {
            line += 1;
            const m = l.match(/^\(define\s+\(?([^\s()]+)/);
            if (!m) continue;
            const name = m[1];
            if (seen.has(name)) dups.push(`${name} at lines ${seen.get(name)} and ${line}`);
            else seen.set(name, line);
        }
        assert.ok(seen.size > 0, `no top-level defines read from ${file}; the scan's shape no longer matches the file`);
        assert.deepEqual(dups, [], `defined twice in ${file}: ${dups.join('; ')}`);
    });
}
