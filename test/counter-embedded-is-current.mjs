// examples/counter-embedded.html is a build product that is committed,
// and until this cell nothing compared it against what its generator
// produces.  It drifted twice.  The second time was not a discovery --
// c7c80f2 CAUSED it, knowingly, and said so, because the repair that
// stopped the printer writing <big-flonum> made every artifact holding
// that string stale the moment it landed.
//
// AND THE GENERATOR ITSELF HAD BEEN BROKEN FOR SEVEN DAYS.  0647569
// narrowed an exemption on 2026-09-11 and three examples stopped
// compiling, this page's source among them; 1.7.1 and 1.7.2 both shipped
// that way.  Nothing noticed, because nothing ran it.  So the artifact
// was not merely out of date -- the one mechanism that could have
// refreshed it did not work, and no reading anywhere would have said so.
//
// WHAT THIS CELL CHECKS, and the shape is deliberate: it runs THE
// GENERATOR, into a temporary file, and compares bytes.  It does not
// re-implement the generator's two steps.  A cell that spelled out
// `goeteiac then run.mjs` would be a second copy of the recipe, and a
// second copy of a recipe is the defect this whole batch has been about
// -- string->number was a second copy of the reader, the placeholder in
// the html was a second copy of the printer's output.  The generator
// grew an optional OUTFILE argument so this cell could call the real
// thing without writing into the tree under test.
//
// DETERMINISM WAS MEASURED BEFORE THIS WAS WRITTEN, because a gate that
// compares raw bytes is only honest if the bytes are reproducible: two
// runs in one tree and a third in a worktree at a different path all
// produced 7e5ac1d9f9d911bfb21385b63b98e0e4.  Nothing here normalises
// anything, and that is the point -- whatever a normaliser removed would
// be the one thing this gate could no longer see.
//
// SCOPE, as a number.  examples/ holds 39 tracked .wasm and 47 tracked
// .html files.  Exactly one of them -- this one -- has a committed
// generator, so this cell can check exactly one.  The other 85 are
// unchecked and their sources cannot be re-derived from this tree at
// all.  This cell stays green with every one of them stale.
//
// WHAT IT WILL ANSWER LATER.  Regenerating today made the page grow 47%,
// from 126622 to 185647 bytes, most of it the embedded wasm data URI
// going from 63222 to 96158.  That is attributed to ten days of compiler
// output rather than proved, because nobody measured it per release.
// Once this gate is running, the next time the compiler's output moves
// the artifact is regenerated and compared, and the diff is evidence
// rather than attribution.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const committed = path.join(root, 'examples', 'counter-embedded.html');
const generator = path.join('examples', 'mk-counter-embedded.sh');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-counter-'));
const fresh = path.join(tmp, 'counter-embedded.html');

// Taken BEFORE the generator runs, so the row below can say whether the
// tree moved rather than assume it did not.
const beforeBytes = fs.readFileSync(committed);
const beforeMtime = fs.statSync(committed).mtimeMs;

const run = spawnSync('sh', [generator, fresh],
                      { cwd: root, encoding: 'utf8', timeout: 300000 });
const runText = ((run.stdout || '') + (run.stderr || '')).trim();

// THE HARD GATE COMES FIRST, and it exists because of a reading taken
// during this batch: a determinism check reported "identical" after two
// runs that had both failed at their first step, leaving the file
// untouched.  It compared two copies of something nothing had written.
// So nothing below is allowed to compare until the generator is known to
// have succeeded AND to have produced a non-empty file.
test('the generator ran and produced something', () => {
    assert.equal(run.status, 0,
        'the generator failed (rc=' + run.status + '): ' + runText);
    assert.ok(fs.existsSync(fresh), 'the generator exited 0 and wrote no file');
    assert.ok(fs.statSync(fresh).size > 0, 'the generator wrote an empty file');
});

// A GENERATOR MUST NOT WRITE THE TREE IT IS BEING CHECKED AGAINST, and
// this row is the only one here that is not about the artifact.  The two
// above ask whether the page is right; the control below asks whether
// the comparison is reaching either file.  This one asks whether THIS
// CELL contaminated the thing it is measuring -- because a gate that
// rewrites its subject produces a green it manufactured itself, and that
// green is indistinguishable from an earned one.  It compares mtime as
// well as bytes, so "it wrote the same content" is still a failure: the
// question is whether it wrote at all, not whether the write was
// harmless.
//
// It is not hypothetical politeness either.  Before OUTFILE existed the
// script redirected straight onto the committed path, and a run that
// compiled but died partway through PUBLISHED the output of that failed
// run: measured at 185647 bytes, structurally complete, and
// indistinguishable from a good page, with the failure surviving only in
// an exit code nothing downstream reads.  That is worse than a truncated
// file, which at least looks wrong.
test('running the generator did not touch the committed artifact', () => {
    assert.deepEqual(fs.readFileSync(committed), beforeBytes,
        'the generator wrote into the tree under test');
    assert.equal(fs.statSync(committed).mtimeMs, beforeMtime,
        'the committed artifact was rewritten, even if with identical bytes');
});

test('the committed page is what the generator produces today', () => {
    const a = fs.readFileSync(fresh);
    const b = fs.readFileSync(committed);
    if (a.equals(b)) return;
    const al = a.toString('utf8').split('\n');
    const bl = b.toString('utf8').split('\n');
    const diffs = [];
    for (let i = 0; i < Math.max(al.length, bl.length) && diffs.length < 4; i++) {
        if (al[i] !== bl[i]) {
            diffs.push(`line ${i + 1}:\n  fresh:     ${(al[i] ?? '(absent)').slice(0, 120)}\n  committed: ${(bl[i] ?? '(absent)').slice(0, 120)}`);
        }
    }
    assert.fail('examples/counter-embedded.html is not what its generator produces.\n'
        + `fresh ${a.length} bytes, committed ${b.length} bytes\n`
        + diffs.join('\n')
        + '\nRegenerate with: sh examples/mk-counter-embedded.sh');
});

// CONTROL.  Every row above passes if the comparison is between two
// copies of the same thing for the wrong reason -- if `fresh` were a
// copy OF the committed file rather than a fresh build.  Perturbing the
// committed bytes must make the comparison red; if it does not, the
// comparison is not reaching either file.
test('CONTROL the comparison notices a difference', () => {
    const perturbed = path.join(tmp, 'perturbed.html');
    fs.writeFileSync(perturbed, Buffer.concat([fs.readFileSync(committed), Buffer.from('x')]));
    assert.ok(!fs.readFileSync(fresh).equals(fs.readFileSync(perturbed)),
        'a one-byte change did not register, so this comparison proves nothing');
});

test('cleanup', () => {
    fs.rmSync(tmp, { recursive: true, force: true });
});
