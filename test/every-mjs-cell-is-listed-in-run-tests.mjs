// A NAMED LIST DOES NOT SHOUT FOR WHAT IS MISSING FROM IT.
//
// test/*.ss is a glob, so an .ss cell runs the moment it is written.
// test/*.mjs is not: every .mjs is named in run-tests.sh by hand, in
// one of three places (run_mjs lines, an explicit if-block, or the for
// loop near the end).  Writing the file is therefore not enough, and
// the failure mode is silence -- the cell sits in test/ and the round
// is green without it.
//
// This has already happened here.  The comment above that for loop says
// so in the tree's own words: "Three cells added on 2026-09-09.  They
// sat in test/ for hours without running, which is what the check below
// is for."  But the check below is ANOTHER NAMED LIST.  It records the
// three that were missed; it cannot notice the fourth.
//
// So the guard is this file rather than a longer list.  It is the one
// shape that covers a cell nobody has written yet.
//
// WHAT IT CHECKS, EXACTLY, because a check that is wider than its
// comment is worse than no check: that each test/*.mjs appears on some
// line of run-tests.sh that is not a comment.  That is weaker than "is
// actually executed" -- a name inside a string, or in a branch that
// never runs, would satisfy it.  It is not weaker in the direction that
// matters: a file NOT mentioned at all cannot possibly run, and that is
// the failure this is for.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const runner = path.join(root, 'run-tests.sh');

const mentioned = (() => {
    const set = new Set();
    for (const line of fs.readFileSync(runner, 'utf8').split('\n')) {
        if (/^\s*#/.test(line)) continue;
        for (const m of line.matchAll(/test\/[A-Za-z0-9._-]+\.mjs/g)) set.add(m[0]);
    }
    return set;
})();

const present = fs.readdirSync(path.join(root, 'test'))
    .filter(n => n.endsWith('.mjs')).map(n => 'test/' + n).sort();

test('every .mjs cell in test/ is named in run-tests.sh', () => {
    const missing = present.filter(p => !mentioned.has(p));
    assert.deepEqual(missing, [],
        'these cells exist and nothing runs them: ' + missing.join(' '));
});

// The other direction is a different defect and gets its own row: a
// name in run-tests.sh with no file behind it is a cell that was
// deleted or renamed while the runner went on calling for it.  The
// runner would report that as a failure for .ss (it says "no such
// file"), but an .mjs named in the for loop just fails to start, and
// what that looks like depends on which of the three places named it.
test('every .mjs named in run-tests.sh exists', () => {
    const ghosts = [...mentioned].filter(m => !fs.existsSync(path.join(root, m))).sort();
    assert.deepEqual(ghosts, [],
        'run-tests.sh calls for cells that are not there: ' + ghosts.join(' '));
});

// CONTROL.  Both rows above pass when test/ is empty and when the
// runner names nothing, so on their own they do not establish that the
// two readings were taken at all.  This row fails if either side comes
// back empty -- the shape of a broken instrument rather than a broken
// tree, and the reading that a gate comparing two empty sets prints as
// agreement.
test('both readings are non-empty', () => {
    assert.ok(present.length > 0, 'no .mjs cells were found in test/');
    assert.ok(mentioned.size > 0, 'no .mjs names were found in run-tests.sh');
});
