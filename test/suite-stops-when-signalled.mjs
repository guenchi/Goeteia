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
// EVERY TRACKED SHELL SCRIPT, not just the suite.  The first version of
// this cell watched run-tests.sh alone, because run-tests.sh was where
// the defect was tripped over.  A census then found the same shape in
// build-self.sh, rebuild.sh and test/mutate.sh -- the last of which
// removes a git worktree and prunes, and would have carried on doing
// mutation work without one.  A guard that watches the one instance you
// happened to hit is a map of the entries nobody is watching.
//
// A second shape came with it.  `trap ... EXIT` alone reads like "this
// runs no matter what" and does not: measured on this machine, an
// uncaught TERM runs the EXIT trap under bash but NOT under dash or
// zsh.  /bin/sh is bash here and dash on most Linux systems, so a script
// relying on EXIT alone leaks there and cannot leak here.  That is why
// the rows below assert the workspace is gone rather than trusting the
// trap list to look right.
//
// WHAT THIS CELL DOES NOT DO: it does not run any of those scripts.  It
// lifts their trap lines OUT of them, puts them in a small script that
// does work after the signal, and signals that.  Lifting rather than
// restating is the point -- a cell that spelled the expected trap lines
// out here would be checking its own copy of them, and the copy is
// exactly what stops being true.  What is asserted is BEHAVIOUR under a
// signal, so a different spelling that also stops is free to replace
// this one.
import { test } from 'node:test';
import assert from 'node:assert';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;

// Derived from git, not from a list here: a list here is a second place
// to add a script to, and the one that gets forgotten is always the
// second one.
const scripts = spawnSync('git', ['ls-files', '*.sh'],
                          { cwd: root, encoding: 'utf8' })
    .stdout.split('\n').filter(Boolean)
    .map(f => ({ file: f,
                 traps: readFileSync(join(root, f), 'utf8')
                     .split('\n').filter(l => /^\s*trap /.test(l)) }))
    .filter(s => s.traps.length > 0);

const dir = mkdtempSync(join(tmpdir(), 'goeteia-signal-'));

// EVERY SHELL ON THIS MACHINE, and that is what makes the second shape
// visible at all.  /bin/sh here is bash, whose EXIT trap runs on an
// uncaught signal; dash's and zsh's do not.  Probing only /bin/sh, this
// cell stayed GREEN with the EXIT-only spelling restored -- measured,
// by reverting the fix and watching it pass.  A guard that is green
// because of the machine it runs on is not a guard, so the probe runs
// under each shell present and a failure under any of them is a
// failure.  On a machine with only one shell this narrows honestly, and
// the count row below says how many were found.
const SHELLS = ['/bin/sh', '/bin/dash', '/bin/zsh', '/bin/bash']
    .filter(sh => existsSync(sh));

// A stand-in for the suite: it makes the same kind of workspace, installs
// the suite's OWN trap lines, then signals itself and tries to keep
// working -- which is what a suite does, since a signal can arrive at any
// point in a long sequential script.
function runProbe(name, traps, sig) {
    const tag = name.replace(/[^a-z0-9]+/gi, '-') + '-' + sig;
    const marker = join(dir, `continued-${tag}`);
    const workspace = join(dir, `ws-${tag}`);
    const script = join(dir, `probe-${tag}.sh`);
    mkdirSync(workspace, { recursive: true });
    writeFileSync(join(workspace, 'artifact'), 'x');
    writeFileSync(script, [
        '#!/bin/sh',
        // The names these traps actually clean up.  A script's trap is
        // lifted verbatim, so the probe has to supply the variables it
        // refers to and point them all at one workspace.
        `T="${workspace}"`,
        `W="${workspace}"`,
        `STAGED="${workspace}/staged"`,
        `REPO="${workspace}"`,
        ...traps.map(l => l.trim()),
        `kill -s ${sig} "$$"`,
        // Only reached if the handler returned instead of exiting.
        `printf 'x' > "${marker}"`,
        `[ -d "${workspace}" ] || printf 'workspace was deleted under the run' >> "${marker}"`,
        '',
    ].join('\n'));
    const out = [];
    for (const shell of SHELLS) {
        rmSync(marker, { force: true });
        rmSync(workspace, { recursive: true, force: true });
        mkdirSync(workspace, { recursive: true });
        writeFileSync(join(workspace, 'artifact'), 'x');
        const r = spawnSync(shell, [script], { encoding: 'utf8', timeout: 30000 });
        out.push({ shell, status: r.status, continued: existsSync(marker),
                   cleaned: !existsSync(workspace),
                   note: existsSync(marker) ? readFileSync(marker, 'utf8') : '' });
    }
    return out;
}

// THE LIFT IS A ROW.  If no script with traps could be found -- a moved
// directory, a changed listing, a regex that stopped matching -- every
// row below would run against an empty list and pass, having tested
// nothing at all.
test('tracked shell scripts with traps were found', () => {
    assert.ok(scripts.length >= 4,
        `found ${scripts.length} tracked .sh files with a trap; this cell is not `
        + 'reading the things it claims to measure, and an empty list passes '
        + 'every row below');
    assert.ok(scripts.some(s => s.file === 'run-tests.sh'),
        'run-tests.sh is not among them, which is where this started');
    assert.ok(SHELLS.length >= 1, 'no shell to probe with');
    if (SHELLS.length < 2)
        console.log(`NOT MEASURED HERE (only ${SHELLS[0]} is present, so the `
            + 'EXIT-trap-on-uncaught-signal difference between shells cannot be '
            + 'exercised; install dash to cover it)');
});

for (const { file, traps } of scripts) {
    for (const sig of ['TERM', 'INT']) {
        test(`${file} stops on ${sig} instead of continuing without its workspace`, () => {
            const runs = runProbe(file, traps, sig);
            const kept = runs.filter(r => r.continued)
                .map(r => `${r.shell}${r.note ? ' (' + r.note + ')' : ''}`);
            assert.deepStrictEqual(kept, [],
                `after ${sig}, work written after the signal still ran under: `
                + `${kept.join(', ')}.  A handler that does not exit returns to `
                + 'where the signal arrived, so the script carries on with '
                + 'whatever the handler removed already gone.  Signal traps '
                + 'should exit and let the EXIT trap do the removing.');
            const zero = runs.filter(r => r.status === 0).map(r => r.shell);
            assert.deepStrictEqual(zero, [],
                `dying of ${sig} reported status 0 under: ${zero.join(', ')}; a `
                + 'script killed by a signal must not be indistinguishable from '
                + 'one that finished');
            const leaked = runs.filter(r => !r.cleaned).map(r => r.shell);
            assert.deepStrictEqual(leaked, [],
                `after ${sig} the workspace was left behind under: ${leaked.join(', ')}. `
                + 'An EXIT trap alone is not a cleanup guarantee -- an uncaught '
                + 'signal runs it under bash but not under dash or zsh, and '
                + '/bin/sh is dash on most Linux systems, so this leaks exactly '
                + 'where nobody is looking.');
        });
    }
}

// CONTROL.  Every row above passes if the probe never reaches its own
// marker for some reason unrelated to traps -- a script that fails to
// start, a kill that does nothing.  With a handler that deliberately
// returns, the probe MUST report continuing; if it does not, the probe
// is not measuring what it claims and the greens above are empty.
test('CONTROL the probe notices a handler that returns', () => {
    const marker = join(dir, 'control-marker');
    const workspace = join(dir, 'control-ws');
    const script = join(dir, 'control.sh');
    mkdirSync(workspace, { recursive: true });
    writeFileSync(script, [
        '#!/bin/sh',
        `T="${workspace}"`,
        `trap 'rm -rf "$T"' EXIT INT TERM`,
        `kill -s TERM "$$"`,
        `printf 'x' > "${marker}"`,
        `[ -d "${workspace}" ] || printf 'workspace was deleted under the run' >> "${marker}"`,
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
