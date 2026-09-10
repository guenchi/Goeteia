// The page verifier's shader check has nothing watching it.
//
// rt/verify.mjs used to accept every shader: its recording context's
// compileShader did nothing and its getShaderParameter answered true,
// so any shader defect passed page verification.  That was fixed by
// putting a page's shaders in front of a real GLSL compiler after the
// replay.
//
// The fix arrived with no guard of its own.  Removing the mechanism
// entirely -- so that no shader is ever collected and no shader row is
// ever produced -- leaves test/verify.mjs at 19/19 and
// test/shader-compile.mjs at 3/3.  It can go back to being a stub in
// silence, which is the shape of the defect it was written to remove:
// a thing that answers yes and is believed.
//
// test/shader-compile.mjs does not cover it either, and the reason is
// worth stating because it is not obvious from the name: that file
// runs an external compiler directly on the GLSL this tree EMITS.  It
// never imports rt/verify.mjs, so nothing it asserts passes through
// the code that verifies a PAGE.
//
// The last test here is the one that matters most.  A check that
// cannot be run must say so and must not report a pass -- collapsing
// "unverified" into "ok" is how the stub survived the first time.
import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { verifyFile } from '../rt/verify.mjs';

const PAGES = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)), 'pages');
const page = name => path.join(PAGES, name);
const shaderRow = r =>
    (r.checks || []).find(c => c.kind === 'shaders')
    || (r.errors || []).find(e => e.stage === 'shaders');

// CONTROL: a page whose shaders compile passes, and says that it
// checked them.  Without this the rows below are satisfied by a
// verifier that refuses every page.
test('CONTROL a page with valid shaders passes and reports the check', async () => {
    const r = await verifyFile(page('shader-ok.ss'), {});
    assert.equal(r.ok, true, JSON.stringify(r.errors));
    assert.ok(shaderRow(r), 'no shader row at all: the check did not run');
});

test('a page whose shader will not compile fails at the shader stage', async () => {
    const r = await verifyFile(page('shader-syntax.ss'), {});
    assert.equal(r.ok, false, 'a page with a broken shader passed verification');
    const e = (r.errors || []).find(x => x.stage === 'shaders');
    assert.ok(e, 'it failed, but not at the shader stage');
    assert.match(e.message, /ERROR/,
                 "the report does not carry the compiler's own words");
});

// A shader that is valid text and calls a function the dialect does
// not have.  Nothing that reads the text can catch this; only a
// compiler that knows the dialect can.
test('a page calling a function its dialect lacks fails too', async () => {
    const r = await verifyFile(page('shader-dfdx.ss'), {});
    assert.equal(r.ok, false, 'a shader calling an absent function passed');
    const e = (r.errors || []).find(x => x.stage === 'shaders');
    assert.ok(e, 'it failed, but not at the shader stage');
});

// THE ONE THAT KEEPS THIS HONEST.  With no compiler available, the
// broken page must come back UNVERIFIED and must not come back as a
// pass of the shader check.
test('with no compiler, the check is announced as not exercised, not passed', async () => {
    const saved = process.env.GOETEIA_CHROME;
    process.env.GOETEIA_CHROME = 'none';
    try {
        const r = await verifyFile(page('shader-syntax.ss'), {});
        const row = shaderRow(r);
        assert.ok(row, 'no shader row: silence is what the stub did');
        const detail = row.detail || row.message || '';
        assert.match(detail, /NOT EXERCISED HERE/,
                     'a check that could not run did not say so');
        assert.doesNotMatch(detail, /compiled by a real GLSL compiler/,
                            'it reported a pass it could not have made');
    } finally {
        if (saved === undefined) delete process.env.GOETEIA_CHROME;
        else process.env.GOETEIA_CHROME = saved;
    }
});
