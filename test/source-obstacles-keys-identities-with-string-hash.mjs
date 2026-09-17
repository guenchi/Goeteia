// (gfx obstacles) arrived carrying its own string hash, a second copy of
// the runtime's multiply-by-31 rolling hash with a smaller modulus.  Its
// stated reason, in its own comment, was that the public string-hash
// promoted intermediates to bignums; that was repaired in 7286818, so
// the private copy became one rule written in two places and was
// deleted.
//
// THIS IS A SOURCE CHECK, AND IT SAYS SO, because no behavioural cell
// can witness the deletion.  The identity table is a local in
// make-obstacle-index: it is read, written, and then not returned -- the
// value handed back is (vector <grid> <by-bounds>).  So the table never
// escapes, its equality predicate is string=?, and a collision therefore
// cannot change any answer the library gives.  A cell asserting "the
// index still tells two colliding identities apart" passes under the old
// hash, under the new hash, AND if the swap were forgotten, which is
// precisely the case it would exist to catch.  Rather than ship a
// behavioural cell that is green for the wrong reason, the wiring is
// checked where it is actually visible: in the text.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const file = 'lib/gfx/obstacles.ss';

test(`${file} keys identities with the shared string-hash`, () => {
    const full = path.join(root, file);
    assert.ok(fs.existsSync(full), `${file} is missing; this cell guards its identity table and cannot run without it`);
    const text = fs.readFileSync(full, 'utf8');

    // The scan must prove it still understands the file.  Without this a
    // rename of make-obstacle-index would make every assertion below
    // vacuously true and the cell would go green having read nothing.
    const tables = text.match(/\(make-hashtable\s+(\S+)/g) ?? [];
    assert.ok(tables.length > 0,
        `no (make-hashtable ...) read from ${file}; the scan's shape no longer matches the file, so its silence means nothing`);

    const privateHashes = [...text.matchAll(/\(define\s+\(\$?[A-Za-z0-9!?*<>=/-]*(?:id-)?hash[A-Za-z0-9!?*<>=/-]*\s/g)].map(m => m[0].trim());
    assert.deepEqual(privateHashes, [],
        `${file} defines its own hash again: ${privateHashes.join('; ')} -- the runtime's string-hash is bounded since 7286818, so a second copy is one rule in two places`);

    const hashArguments = tables.map(t => t.replace(/\(make-hashtable\s+/, ''));
    assert.deepEqual(hashArguments, ['string-hash'],
        `the identity table is built with ${hashArguments.join(', ')}; it must use the runtime's string-hash`);
});
