// An interrupted run must STOP, not keep going with its workspace
// deleted.
//
// run-tests.sh used to carry `trap 'rm -rf "$T"' EXIT INT TERM`, and a
// handler that does not exit RETURNS to where the signal arrived.  So on
// a TERM the artifact directory was removed and the run continued into
// it.  Every remaining cell then failed trying to write a file under a
// path that no longer existed:
//
//   FAIL test/import-specs.ss (stage0 compile error)
//   Exception in open-file-output-port: ... /goeteia-tests.7KlYFA/test.wasm:
//     no such file or directory
//
// Measured on two runs stopped on 2026-09-18.  One of those logs reports
// twelve failures of which six are real -- the six that had already
// happened before the signal.  That is what makes it worth a cell rather
// than a comment: an interrupted run does not merely stop, it
// MANUFACTURES failures that name real test files, and the number a
// reader counts is wrong in the direction of alarm.  A stopped run that
// looks broken sends someone to debug a defect that is not there.
//
// WHAT THIS CELL DOES NOT DO: it does not run the suite.  It lifts the
// trap lines OUT OF run-tests.sh, puts them in a small script that does
// work after the signal, and signals it.  Lifting rather than restating
// is the point -- a cell that spelled the expected trap lines out here
// would be checking its own copy of them, and the copy is exactly what
// stops being true.  What is asserted is BEHAVIOUR under a signal, so a
// different spelling that also stops is free to replace this one.
import { test } from 'node:test';
import assert from 'node:assert';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const suite = readFileSync(join(root, 'run-tests.sh'), 'utf8');

// Every top-level trap in the suite, in order, taken from the file.
const traps = suite.split('\n').filter(l => /^trap /.test(l));

const dir = mkdtempSync(join(tmpdir(), 'goeteia-signal-'));

// A stand-in for the suite: it makes the same kind of workspace, installs
// the suite's OWN trap lines, then signals itself and tries to keep
// working -- which is what a suite does, since a signal can arrive at any
// point in a long sequential script.
function runProbe(sig) {
    const marker = join(dir, `continued-${sig}`);
    const script = join(dir, `probe-${sig}.sh`);
    writeFileSync(script, [
        '#!/bin/sh',
        `T=$(mktemp -d "\${TMPDIR:-/tmp}/goeteia-tests.XXXXXX") || exit 1`,
        ...traps,
        `kill -s ${sig} "$$"`,
        // Only reached if the handler returned instead of exiting.
        `printf 'x' > "${marker}"`,
        `[ -d "$T" ] || printf 'workspace was deleted under the run' >> "${marker}"`,
        '',
    ].join('\n'));
    const r = spawnSync('sh', [script], { encoding: 'utf8', timeout: 30000 });
    return { status: r.status, continued: existsSync(marker),
             note: existsSync(marker) ? readFileSync(marker, 'utf8') : '' };
}

// THE LIFT IS A ROW.  If the traps could not be found -- renamed file,
// changed indentation, a trap moved into a function -- every row below
// would run against an empty list and pass, having tested a script with
// no traps at all.
test('the suite\'s trap lines were found', () => {
    // One, not two.  An earlier spelling required two lines here, which
    // made this row fail whenever the SHAPE was wrong -- the thing the
    // rows below exist to report.  A row that fires for another row's
    // reason cannot be read: the reader learns that something is wrong
    // without learning which.  This one asks only whether the lift
    // reached the file.
    assert.ok(traps.length >= 1,
        `found ${traps.length} top-level trap lines in run-tests.sh; this cell `
        + 'is not reading the thing it claims to measure, and the rows below '
        + 'would pass on a script with no traps');
    assert.ok(traps.some(l => /EXIT/.test(l)),
        'no EXIT trap found, so nothing here is about cleanup');
});

for (const sig of ['TERM', 'INT']) {
    test(`a ${sig} stops the run instead of continuing into a deleted workspace`, () => {
        const r = runProbe(sig);
        assert.ok(!r.continued,
            `after ${sig} the script kept running${r.note ? ' -- ' + r.note : ''}. `
            + 'A handler that does not exit returns to where the signal arrived, '
            + 'so the run carries on with its artifact directory removed and '
            + 'every later cell fails on a missing path.  Signal traps should '
            + 'exit and let the EXIT trap do the removing.');
        assert.ok(r.status !== 0,
            `dying of ${sig} reported status ${r.status}; a stopped run must not `
            + 'be distinguishable from a passing one only by its log');
    });
}

// CONTROL.  Every row above passes if the probe never reaches its own
// marker for some reason unrelated to traps -- a script that fails to
// start, a kill that does nothing.  With a handler that deliberately
// returns, the probe MUST report continuing; if it does not, the probe
// is not measuring what it claims and the greens above are empty.
test('CONTROL the probe notices a handler that returns', () => {
    const marker = join(dir, 'control-marker');
    const script = join(dir, 'control.sh');
    writeFileSync(script, [
        '#!/bin/sh',
        `T=$(mktemp -d "\${TMPDIR:-/tmp}/goeteia-tests.XXXXXX") || exit 1`,
        `trap 'rm -rf "$T"' EXIT INT TERM`,
        `kill -s TERM "$$"`,
        `printf 'x' > "${marker}"`,
        `[ -d "$T" ] || printf 'workspace was deleted under the run' >> "${marker}"`,
        '',
    ].join('\n'));
    spawnSync('sh', [script], { encoding: 'utf8', timeout: 30000 });
    assert.ok(existsSync(marker),
        'the shape this cell exists to refuse did NOT continue after a signal, '
        + 'so this probe cannot tell the two apart and the rows above prove nothing');
    assert.match(readFileSync(marker, 'utf8'), /workspace was deleted/,
        'the old shape continued but its workspace survived, so the probe is not '
        + 'reproducing the failure that was measured');
});

test('cleanup', () => {
    rmSync(dir, { recursive: true, force: true });
});
