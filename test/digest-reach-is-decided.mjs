// Every tracked file is either in the tree digest or exempted from it
// with a reason that is checked again on every run.
//
// The digest in run-tests.sh identifies the tree a run measured, and
// its first line and last line are compared to catch a tree that
// changed under the run.  Its reach is a list of directories and
// extensions, and that list has left out a file the cells depend on
// four times, each in a different dress: bin/goeteiac has no extension;
// test/ fixtures had extensions nobody listed; docs/ was added with the
// wrong extension; and examples/, three root scripts and package.json
// were outside it while cells compiled, read or ran them -- two of those
// only at second hand, a cell running code that opens the file.
//
// Widening the reach to every file was considered and refused beside
// digest_now: it would hash editor leftovers and anything dropped under
// test/, and turn a gate into a noise source.  So the list stays, and
// this cell makes its omissions loud.  It does NOT judge what is a
// dependency -- a search for the name misses computed names, and a
// search for code lines reports a hint inside an echo -- it requires a
// DECISION for each tracked file the list leaves out.
//
// The reach is read from `run-tests.sh --digest-files`, the function
// digest_now hashes, and not restated here: a second copy of the list is
// the thing that drifts.
import { test } from 'node:test';
import assert from 'node:assert';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const run = (cmd, args) => spawnSync(cmd, args, { cwd: root, encoding: 'utf8' });

const reach = new Set(run('sh', ['run-tests.sh', '--digest-files']).stdout
    .split('\n').filter(Boolean));
const tracked = run('git', ['ls-files']).stdout.split('\n').filter(Boolean);

const rows = readFileSync(join(root, 'test', 'digest-exemptions.tsv'), 'utf8')
    .split('\n')
    .filter(l => l.trim() && !l.startsWith('#'))
    .map(l => l.split('\t'))
    .map(([pattern, check, reason]) => ({ pattern, check, reason }));

// * stays inside one path segment, and nothing else is special.
const toRe = p => new RegExp('^' + p.split('*')
    .map(s => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('[^/]*') + '$');
rows.forEach(r => { r.re = toRe(r.pattern); });

// Code lines only: a comment that mentions a file is not a reader.
const CODE_ROOTS = ['test', 'run-tests.sh', 'rt', 'bin', 'tools', 'src', 'lib'];
const COMMENT = /^\s*(\/\/|;;|#|\*)/;
function codeHits(re) {
    // --untracked: a cell written today and not yet added is exactly the
    // reader this row exists to catch, and git grep skips it by default.
    // The exemption table is left out because it names every exempted file
    // on purpose; it is the one place that is not a reader.  Found when
    // --untracked went in and the table, not yet added, matched itself.
    const g = run('git', ['grep', '--untracked', '-nE', re, '--', ...CODE_ROOTS,
                          ':!test/digest-exemptions.tsv']);
    return g.stdout.split('\n').filter(Boolean)
        .filter(line => !COMMENT.test(line.replace(/^[^:]*:\d+:/, '')));
}

const outside = tracked.filter(f => !reach.has(f));

test('the reach and the tracked list were both read', () => {
    assert.ok(reach.size >= 600, `run-tests.sh --digest-files listed ${reach.size} files`);
    assert.ok(reach.has('run-tests.sh') && reach.has('goeteia.wasm'),
        'the list does not contain the harness and the snapshot, so it is not the digest\'s list');
    assert.ok(tracked.length >= 700, `git ls-files listed ${tracked.length}`);
});

test('every tracked file outside the digest is exempted by a row', () => {
    const undecided = outside.filter(f => !rows.some(r => r.re.test(f)));
    assert.deepStrictEqual(undecided, [],
        'these tracked files are neither in the tree digest nor exempted from it.  '
        + 'Decide each: if any cell, or any code a cell runs, opens it, bring it into '
        + 'digest_files in run-tests.sh; if nothing does, add a row to '
        + 'test/digest-exemptions.tsv with a check that proves it:\n  '
        + undecided.join('\n  '));
});

test('every exemption row is complete and still exempts something', () => {
    const bad = rows.filter(r => !r.pattern || !r.check || !r.reason
                                 || !outside.some(f => r.re.test(f)))
        .map(r => `${r.pattern || '(no pattern)'}: `
             + (!r.check || !r.reason ? 'missing a check or a reason'
                : 'matches no tracked file outside the digest -- it is stale'));
    assert.deepStrictEqual(bad, [], bad.join('\n'));
});

test('no exemption covers a file the digest already holds', () => {
    const both = rows.flatMap(r => [...reach].filter(f => r.re.test(f))
        .map(f => `${f} (row ${r.pattern})`));
    assert.deepStrictEqual(both, [],
        'a file is both hashed and exempted, so one of the two decisions is wrong');
});

test('every exemption\'s check still finds no reader', () => {
    const readers = rows.flatMap(r => codeHits(r.check)
        .map(h => `${r.pattern}: ${h.slice(0, 140)}`));
    assert.deepStrictEqual(readers, [],
        'code now mentions an exempted file, so something may have started reading '
        + 'it: bring it into digest_files, or narrow the check and say why:\n  '
        + readers.join('\n  '));
});

// CONTROL for the row above.  A zero from a search is evidence only if
// the same search is heard reporting a non-zero.  build.sh is known to
// be opened by rt/dev.mjs, which a cell runs, so the same machinery must
// find it.
test('CONTROL the reader check finds a reader that exists', () => {
    const hits = codeHits('build\\.sh');
    assert.ok(hits.some(h => h.startsWith('rt/dev.mjs:')),
        'the check did not find rt/dev.mjs opening build.sh, so its zeros above '
        + 'are not evidence of anything');
});
