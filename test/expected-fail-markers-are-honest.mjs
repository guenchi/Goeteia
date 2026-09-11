// The marker that says a cell is SUPPOSED to be failing has to be a
// checked claim, not prose, because prose about a cell's current colour
// decays the moment the defect is fixed and nothing notices.
//
// It decayed here, at scale: a sweep found 67 cells carrying "RED ON
// PURPOSE" and measured every one of them GREEN -- the marker had no
// discriminating power left anywhere in the tree.  Worse than useless,
// it was reassuring in the wrong direction: had any of those regressed,
// the suite would have printed FAIL and the reader would have opened the
// file to a comment saying the red was intentional.  Twelve of them went
// further and asserted a NAMED defect was "still live <date>" -- decoder
// bounds, a GLB container, a fixnum overflow -- which feeds a re-count
// of open High findings at exactly the decision points where that count
// is consulted.
//
// So the retired phrase is banned outright, and the replacement phrase
// is policed: a cell may only claim to be expected-fail if it actually
// fails.  What makes that checkable is that failure here means the
// SELF-HOSTED path refuses or mis-answers it -- stage0 is Chez-hosted
// and can disagree with the compiler under test, which is precisely how
// the directive cell below is stage0-green and stage1-red.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import url from 'node:url';

const here = path.dirname(url.fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const RETIRED = 'RED ON PURPOSE';
const MARKER = 'EXPECTED FAIL';

// This file is excluded from its own scan: it has to SPELL the retired
// phrase in order to police it, so including itself would make the gate
// permanently red on its own definition -- a check that cannot pass is
// as useless as one that cannot fail.
const self = path.basename(url.fileURLToPath(import.meta.url));
const cells = fs.readdirSync(here)
    .filter(f => (f.endsWith('.ss') || f.endsWith('.mjs')) && f !== self)
    .map(f => path.join(here, f));

test('the retired status marker appears nowhere', () => {
    const offenders = cells.filter(f => fs.readFileSync(f, 'utf8').includes(RETIRED));
    assert.deepEqual(offenders.map(f => path.basename(f)), [],
        `"${RETIRED}" asserts a cell's CURRENT colour and decays silently; ` +
        `state history instead ("written as a red witness at <commit>")`);
});

// A cell wearing the expected-fail marker must really fail.  Run it the
// way the suite would judge it -- self-hosted compile, then run -- and
// require that it does NOT produce its own expect line.  A marker on a
// passing cell is the decay this file exists to stop.
test('every cell claiming to be expected-fail actually fails', () => {
    const marked = cells.filter(f => f.endsWith('.ss') &&
                                     fs.readFileSync(f, 'utf8').includes(MARKER));
    const wrong = [];
    for (const f of marked) {
        const src = fs.readFileSync(f, 'utf8');
        const want = (src.split('\n')[0].match(/^;; expect:\s?(.*)$/) || [, null])[1];
        if (want === null) continue;
        let got = null;
        try {
            const out = path.join(fs.mkdtempSync('/tmp/goeteia-efm-'), 'a.wasm');
            execFileSync('node', [path.join(root, 'rt/compile.mjs'),
                                  path.join(root, 'goeteia.wasm'), f, out],
                         { stdio: 'pipe' });
            got = execFileSync('node', [path.join(root, 'rt/run.mjs'), out],
                               { encoding: 'utf8', stdio: 'pipe' }).trim();
        } catch { got = null; }          // refused or trapped: that IS failing
        if (got === want) wrong.push(path.basename(f));
    }
    assert.deepEqual(wrong, [],
        `these carry "${MARKER}" but the self-hosted path answers correctly; ` +
        `a marker on a passing cell is the decay, rewrite it as history`);
});
