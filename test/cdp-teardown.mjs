// The browser harness removes a throwaway profile directory in a
// `finally`.  On 2026-09-09 that removal threw EACCES once, and the
// test it was tearing down went red -- a test whose shaders had all
// compiled.  The defect is not the EACCES; it is that a teardown
// was in a position to author a verdict at all.
//
// A `finally` that throws also REPLACES an exception already in
// flight, so the same line could hide a real failure behind a cleanup
// error.  That is the half worth pinning, and the second case below is
// the one that pins it.
//
// The original race is a race and cannot be scheduled.  What can be
// staged is the condition it produced: a directory that rmSync cannot
// remove.  A read-only parent gives that on every POSIX system.
import test from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { discardProfile } from '../tools/cdp.mjs';

function unremovable() {
    const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-teardown-'));
    const profile = path.join(parent, 'profile');
    fs.mkdirSync(profile);
    fs.writeFileSync(path.join(profile, 'occupant'), 'x');
    fs.chmodSync(parent, 0o500);           // no write on the parent: unlink is refused
    return { parent, profile };
}
function release({ parent }) {
    fs.chmodSync(parent, 0o700);
    fs.rmSync(parent, { recursive: true, force: true });
}

test('a teardown that cannot remove its directory does not throw', () => {
    const d = unremovable();
    try {
        assert.doesNotThrow(() => discardProfile(d.profile));
    } finally { release(d); }
});

test('a teardown failure does not replace an exception already in flight', () => {
    const d = unremovable();
    // exactly the shape withBrowser has: a body that failed, and a
    // finally that also cannot do its job.  The caller must learn about
    // the body, not about the cleanup.
    const seen = (() => {
        try {
            try { throw new Error('the real failure'); }
            finally { discardProfile(d.profile); }
        } catch (e) { return e.message; }
    })();
    release(d);
    assert.strictEqual(seen, 'the real failure');
});

test('a removable directory is still actually removed', () => {
    // the control: a teardown that never throws is trivially
    // satisfied by a teardown that does nothing.
    const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-teardown-'));
    const profile = path.join(parent, 'profile');
    fs.mkdirSync(profile);
    fs.writeFileSync(path.join(profile, 'occupant'), 'x');
    discardProfile(profile);
    assert.ok(!fs.existsSync(profile), 'the profile directory should be gone');
    fs.rmSync(parent, { recursive: true, force: true });
});
