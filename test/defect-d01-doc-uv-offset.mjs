// RED ON PURPOSE: the texturing example in docs/graphics.md reads the
// vertex NORMAL and calls it a UV.
//
//     (rattr-f32 (gprim-vbase p) (gprim-stride p) 12 n 2)
//
// The third argument is a byte offset.  In the canonical interleave --
// position, normal, uv -- position and normal occupy the first 24
// bytes, so 12 is the middle of the normal and the UV set starts at
// 24.  A reader following the example samples the atlas with a
// normal's x and y.
//
// ⭐ NEITHER SIDE OF THIS COMPARISON IS WRITTEN DOWN HERE.  The
// expected offset is computed by asking (gfx glb) for the stride of
// the layout up to the UV set, and the actual one is parsed out of the
// document.  ⇒ If the layout ever changes, this cell moves with it
// instead of becoming a second stale number beside the first.  A cell
// asserting "the doc should say 24" would have no author for the 24.
//
// ⚠️ The review located this at docs/graphics.md:1304 and the line is
// now 1483.  ⇒ The cell searches for the call rather than for a line,
// because a line number in a document is a fact with a shelf life.
//
// The control is that the call is found at all: if the example is
// rewritten or removed, this cell must say "not found" rather than
// quietly passing on a document that no longer contains what it
// checks.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// the offset of the UV set, from the library rather than from memory
function uvOffsetFromLibrary() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-d01-'));
    const f = path.join(dir, 'p.ss');
    fs.writeFileSync(f, ';; expect: x\n(import (rnrs) (gfx glb))\n' +
                        "(display (glb-stride '(position normal)))\n", 'utf8');
    try {
        execFileSync(path.join(root, 'bin/goeteiac'), [f, `${f}.wasm`],
                     { cwd: root, stdio: 'pipe' });
        const out = execFileSync('node', [path.join(root, 'rt/run.mjs'), `${f}.wasm`],
                                 { cwd: root, encoding: 'utf8' });
        return Number(out.trim());
    } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

const doc = fs.readFileSync(path.join(root, 'docs/graphics.md'), 'utf8');
const call = doc.match(/\(rattr-f32 \(gprim-vbase p\) \(gprim-stride p\) (\d+)/);

test('CONTROL the texturing example is still in the document', () => {
    assert.ok(call, 'the rattr-f32 example was not found in docs/graphics.md');
});

test('the documented UV offset is where the UV set actually starts', () => {
    const want = uvOffsetFromLibrary();
    assert.ok(Number.isFinite(want) && want > 0, `the library answered ${want}`);
    assert.equal(Number(call[1]), want,
                 `the example reads offset ${call[1]}; the UV set starts at ${want}, ` +
                 'so it is sampling the normal');
});
