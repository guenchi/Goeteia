// rt/verify.mjs, judged by pages whose verdict is known.
//
// Four stages, six fixtures in test/pages/.  Three that must pass and
// three that must fail, one at each stage that can fail on its own:
//
//   static.ss    compiles, runs, builds text            -> done
//   slider.ss    a control that really drives the page  -> done
//   gradient.ss  draws, and the picture moves           -> done
//   unclosed.ss  a reader error with a real position    -> compile
//   trap.ss      compiles clean, traps on the first run -> smoke
//   nodraw.ss    a live context, a loop, and no draws   -> draw
//
// nodraw.ss is the fixture the draw stage exists for: "no canvas on
// the page" would be caught by almost anything, while this one links a
// program, uploads vertices and runs a frame loop.  Only counting draw
// calls tells it apart from gradient.ss.
//
// gradient.ss carries the other half of the argument.  It moves by
// itself and answers to nobody, so an interaction test that compared a
// run against ITSELF would call it interactive.  Two assertions below
// pin the differential that stops it: the mock world's clock is frozen
// (two identical runs of an animating page agree byte for byte), and
// the interact stage rejects gradient.ss for having nothing wired --
// not for being unjudgeable.  Unfreeze the clock and both go red.
//
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
    compile, makeWorld, parseNeeds, readChecks, runVerify, scenario,
    signature, verifyBytes, verifyFile,
} from '../rt/verify.mjs';

const PAGES = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)), 'pages');
const page = name => path.join(PAGES, name);

const checkOf = (r, kind) => (r.checks || []).find(c => c.kind === kind);
const why = r => (r.errors || [])
    .map(e => `${e.stage}: ${e.message}`).join('\n');

test('a static page passes compile, smoke and its content checks', async () => {
    const r = await verifyFile(page('static.ss'), {
        custom: [{ kind: 'text_blocks_min', n: 5 },
                 { kind: 'dom_text_min_length', n: 120 },
                 { kind: 'console_matches', pattern: 'static page mounted' }],
    });
    assert.equal(r.ok, true, `stage ${r.stage}\n${why(r)}`);
    assert.equal(r.stage, 'done');
    assert.equal(r.checks.length, 3);
    assert.ok(r.checks.every(c => c.ok));
    assert.equal(r.stats.draws, 0, 'a static page should not be drawing');
});

test('a wired control passes the interact stage', async () => {
    const r = await verifyFile(page('slider.ss'), {
        needs_interact: true,
        custom: [{ kind: 'input_count_min', n: 1 },
                 { kind: 'input_changes', index: 0, by: 'text' }],
    });
    assert.equal(r.ok, true, `stage ${r.stage}\n${why(r)}`);
    // the verdict must name the input it synthesized, not just say "ok"
    assert.match(checkOf(r, 'needs_interact').detail, /input#c-in input=/);
    assert.ok(r.stats.scenarios >= 3,
        'the differential needs the two no-input runs plus the one with input');
});

test('a reader error lands on the compile stage with an exact position', async () => {
    const r = await verifyFile(page('unclosed.ss'), {});
    assert.equal(r.ok, false);
    assert.equal(r.stage, 'compile');
    assert.equal(r.checks.length, 0, 'nothing may be judged after a failed compile');
    const [e] = r.errors;
    assert.equal(e.located, 'exact');
    assert.equal(path.basename(e.file), 'unclosed.ss');
    assert.equal(e.line, 4);
    assert.equal(e.col, 3);
    assert.match(e.excerpt, /^4 \|\s+\(let \(\(n /m);
    assert.match(e.excerpt, /\^/, 'the excerpt must point at the column');
});

test('a run-time trap lands on the smoke stage with the Scheme-level cause', async () => {
    const r = await verifyFile(page('trap.ss'), {});
    assert.equal(r.ok, false);
    assert.equal(r.stage, 'smoke');
    const [e] = r.errors;
    assert.match(e.message, /illegal cast/);
    // "illegal cast" says nothing; the hint has to name what it means here
    assert.match(e.hint, /i31 fixnum range/);
    assert.match(e.hint, /bitwise/);
});

test('a rendering program that never draws lands on the draw stage', async () => {
    const r = await verifyFile(page('nodraw.ss'), { needs_draw: true });
    assert.equal(r.ok, false);
    assert.equal(r.stage, 'draw');
    assert.equal(r.stats.draws, 0);
    // it got a context and uploaded to it -- that is what makes this
    // the sharp case, and the hint must be the one for that case
    assert.ok(r.stats.gl_ops > 0, 'the fixture is meant to reach GL, just not draw');
    const e = r.errors.find(x => x.stage === 'draw');
    assert.match(e.hint, /fx-loop!/);
    assert.doesNotMatch(e.hint, /never did/,
        'that hint is for a page with no GL calls at all');
});

test('an animating page passes the draw stage', async () => {
    const r = await verifyFile(page('gradient.ss'), {
        needs_draw: true,
        custom: [{ kind: 'animates' },
                 { kind: 'some_uniform_varies_over_time' },
                 { kind: 'max_vertices_per_frame', n: 12 }],
    });
    assert.equal(r.ok, true, `stage ${r.stage}\n${why(r)}`);
    assert.ok(r.stats.draws >= 3);
});

test('the mock world is deterministic, which is what the differential rests on', async () => {
    const c = await compile(page('gradient.ss'));
    assert.equal(c.ok, true, 'the fixture must compile for this to mean anything');
    const a = await scenario(c.wasm);
    const b = await scenario(c.wasm);
    assert.equal(a.ok && b.ok, true, 'both runs must survive');
    // the fixture animates, so this is not the trivial case of two
    // still pictures agreeing
    const frames = a.frames.filter(f => f.length);
    assert.notEqual(JSON.stringify(frames.at(-2)), JSON.stringify(frames.at(-1)),
        'the fixture is supposed to move between frames');
    assert.equal(signature(a), signature(b),
        'two runs of the same bytes with no input must agree byte for byte; '
        + 'if they do not, an unfrozen clock or random source is on the render path '
        + 'and no interaction verdict can stand');
});

test('an animating page is not an interactive one', async () => {
    const r = await verifyFile(page('gradient.ss'), { needs_interact: true });
    assert.equal(r.ok, false, 'nothing on this page listens for anything');
    assert.equal(r.stage, 'interact');
    const c = checkOf(r, 'needs_interact');
    assert.notEqual(c.nondet, true,
        'it must be rejected for having nothing wired, not for being unjudgeable');
    assert.match(c.detail, /nowhere to go/);
});

test('an unknown check kind is a failure that names the kinds there are', async () => {
    const r = await verifyFile(page('static.ss'),
                               { custom: [{ kind: 'no-such-check' }] });
    assert.equal(r.ok, false);
    assert.equal(r.stage, 'custom');
    assert.match(r.errors[0].hint, /dom_text_matches/);
});

test('--needs and --checks refuse what they cannot mean', () => {
    assert.deepEqual(parseNeeds('draw,interact'),
                     { needs_draw: true, needs_interact: true });
    assert.deepEqual(parseNeeds('interact'), { needs_interact: true });
    assert.deepEqual(parseNeeds(''), {});
    assert.throws(() => parseNeeds('draws'), /needs/,
        'a misspelt stage must not be silently dropped');
    assert.deepEqual(readChecks('{"needs_draw":true}'), { needs_draw: true });
    assert.throws(() => readChecks('[1,2]'), /JSON object/);
    assert.throws(() => readChecks('not json'), /readable JSON file/);
});

test('the CLI refuses a dangling flag instead of running with nothing required', async () => {
    // `verify page.ss --needs` used to mean "no stages at all", which
    // is the one answer a typo must not silently produce
    assert.equal(await runVerify([page('gradient.ss'), '--needs']), 2);
    assert.equal(await runVerify([]), 2);
    assert.equal(await runVerify([page('gradient.ss'), '--needs', 'draws']), 2);
});

test('an unknown top-level spec key is refused by name', async () => {
    // library boundary FIRST: both entries must throw on their own --
    // a whitelist living only in the CLI's readChecks would leave
    // programmatic callers running with a misspelt requirement
    // silently unenforced
    await assert.rejects(
        () => verifyFile(page('static.ss'), { checks: [] }),
        /unknown check spec key "checks".*"needs_draw".*"needs_interact".*"custom"/s);
    const c = await compile(page('static.ss'), {});
    assert.ok(c.ok);
    await assert.rejects(
        () => verifyBytes(c.wasm, { needs_drow: true }),
        /unknown check spec key "needs_drow"/);
    // the CLI answers bad usage: exit 2, and stderr names the bad key
    // together with the whole legal set
    const errs = [];
    const orig = console.error;
    console.error = (...a) => errs.push(a.join(' '));
    let code;
    try {
        code = await runVerify(
            [page('static.ss'), '--checks', '{"checks":[]}']);
    } finally { console.error = orig; }
    assert.equal(code, 2);
    const text = errs.join('\n');
    for (const want of ['"checks"', 'needs_draw', 'needs_interact', 'custom'])
        assert.ok(text.includes(want), `stderr lacks ${want}: ${text}`);
});

test('normalized and explicitly-empty spellings stay legal', async () => {
    // --needs draw produces whitelisted keys; an explicit custom: []
    // is a declaration of zero checks, not a typo; and the two merge
    assert.equal(await runVerify([page('gradient.ss'), '--needs', 'draw']), 0);
    assert.equal(await runVerify(
        [page('gradient.ss'), '--checks', '{"custom":[]}', '--needs', 'draw']),
        0);
});

test('a glyph-atlas page draws through both mock contexts', async () => {
    const c = await compile(page('spritetext.ss'), {});
    assert.ok(c.ok, JSON.stringify(c.errors || []));
    const r = await verifyBytes(c.wasm, { needs_draw: true });
    assert.equal(r.ok, true, `stage ${r.stage}\n${why(r)}`);
    assert.ok(r.stats.draws > 0, 'the sprite page must issue GL draws');
    // the verdict deliberately omits the world; one scenario exposes
    // both logs
    const t = await scenario(c.wasm, {});
    const ops = t.world.c2d.map(e => e.op);
    assert.ok(ops.includes('fillText'), `2d log has no fillText: ${ops.join(',')}`);
    const texts = t.world.c2d.filter(e => e.op === 'fillText').map(e => e.text);
    assert.ok(texts.some(s => /\S/.test(s)), 'no non-blank glyph was rasterized');
    assert.ok(t.world.gl.some(e => e.op.startsWith('draw')),
              'the GL log lost its draws');
});

test('the 2d mock keeps its contract', () => {
    const w = makeWorld({});
    w.install();
    try {
        const cv = globalThis.document.createElement('canvas');
        const ctx = cv.getContext('2d');
        // writable state, read back as written
        ctx.font = '16px monospace';
        ctx.textBaseline = 'top';
        ctx.fillStyle = '#fff';
        assert.equal(ctx.font, '16px monospace');
        assert.equal(ctx.textBaseline, 'top');
        assert.equal(ctx.fillStyle, '#fff');
        // deterministic measure: 8 px per CODE POINT, so the astral
        // glyph counts once, not twice
        assert.equal(ctx.measureText('').width, 0);
        assert.equal(ctx.measureText('A').width, 8);
        assert.equal(ctx.measureText('A\u{1F600}').width, 16);
        assert.equal(ctx.measureText('A').width, ctx.measureText('A').width);
        // all three drawing ops land in the world's 2d log
        ctx.fillText('hi', 1, 2);
        ctx.fillRect(0, 0, 2, 2);
        ctx.drawImage(cv, 0, 0);
        assert.deepEqual(w.c2d.map(e => e.op),
                         ['fillText', 'fillRect', 'drawImage']);
        // per-kind caching on ONE canvas: every kind gets its OWN
        // object -- a real canvas does not hand "webgl" and "webgl2"
        // the same context -- each stable across repeat calls, and
        // every GL kind still records into the one world.gl log
        const gl = cv.getContext('webgl2');
        const gl1 = cv.getContext('webgl');
        assert.notEqual(gl, ctx);
        assert.notEqual(gl1, gl, '"webgl" and "webgl2" must be distinct contexts');
        assert.equal(cv.getContext('2d'), ctx);
        assert.equal(cv.getContext('webgl2'), gl);
        assert.equal(cv.getContext('webgl'), gl1);
        const before = w.gl.length;
        gl.drawArrays('TRIANGLES', 0, 3);
        gl1.drawArrays('TRIANGLES', 0, 3);
        assert.equal(w.gl.length, before + 2,
                     'every GL kind records into the one world.gl log');
        assert.equal(w.gl[w.gl.length - 1].op, 'drawArrays');
    } finally { w.uninstall(); }
});

test('the CLI refuses an unknown option name', async () => {
    // the sibling of the spec-key whitelist, one level out: `--neds
    // draw` used to parse as an ignored option, so a page that draws
    // nothing verified "ok" with the requirement silently dropped
    const errs = [];
    const orig = console.error;
    console.error = (...a) => errs.push(a.join(' '));
    let code;
    try {
        code = await runVerify([page('nodraw.ss'), '--neds', 'draw']);
    } finally { console.error = orig; }
    assert.equal(code, 2);
    const text = errs.join('\n');
    assert.ok(text.includes('--neds'), `stderr does not name the bad option: ${text}`);
    assert.ok(text.includes('--needs'), `stderr does not list the legal ones: ${text}`);
    // and the correctly-spelled flag still reaches the draw stage,
    // where this fixture belongs (exit 1, not 0 and not 2)
    assert.equal(await runVerify([page('nodraw.ss'), '--needs', 'draw']), 1);
});

test('a misspelt field inside a custom entry is refused by name', async () => {
    // `by` picks the projection; mistyped, it silently selects the
    // default and the check quietly asks a different question
    await assert.rejects(
        () => verifyFile(page('slider.ss'),
                         { custom: [{ kind: 'input_changes', index: 0, bye: 'text' }] }),
        e => {
            assert.match(e.message, /"bye"/);              // the bad field
            assert.match(e.message, /input_changes/);      // the kind
            assert.match(e.message, /"index".*"by"/s);     // its legal fields
            return true;
        });
    // hint is legal on every entry, and a correct spelling passes
    const r = await verifyFile(page('static.ss'),
        { custom: [{ kind: 'text_blocks_min', n: 3, hint: 'add paragraphs' }] });
    assert.equal(r.ok, true, why(r));
});

test('each whitelist mounting point is load-bearing on its own', async () => {
    // readChecks: the CLI's own parse path, checked directly -- no
    // other assertion here reaches it with a bad key
    assert.throws(() => readChecks('{"cheks":{}}'), /unknown check spec key "cheks"/);
    // verifyFile: a bad key must be refused BEFORE compiling, so this
    // uses a source that cannot compile.  If the gate moved to
    // verifyBytes alone, this would come back as a compile error and
    // the key mistake would be invisible.
    await assert.rejects(
        () => verifyFile(page('unclosed.ss'), { needs_drow: true }),
        /unknown check spec key "needs_drow"/);
});

test('prototype-named strings are data, not lookups', async () => {
    // Every table keyed by a user-supplied string is a place where
    // "toString" or "__proto__" can pick up an inherited member
    // instead of being refused.  Each assertion below goes red if its
    // own-property guard is reverted.
    const w = makeWorld({});
    w.install();
    try {
        const cv = globalThis.document.createElement('canvas');
        for (const k of ['constructor', 'toString', '__proto__']) {
            const ctx = cv.getContext(k);
            assert.ok(ctx && typeof ctx === 'object' && 'drawArrays' in ctx,
                      `getContext(${JSON.stringify(k)}) handed back a prototype member`);
        }
    } finally { w.uninstall(); }
    // an unknown KIND that happens to name a prototype member stays a
    // verdict, exactly like any other unknown kind -- not a crash.
    // The verdict has to be the UNKNOWN-KIND one: without the
    // own-property guard, CUSTOM["toString"] is Object.prototype's
    // own toString, which is callable, so it runs as a handler and
    // its garbage result still lands as a failed check at this same
    // stage.  Asserting ok/stage alone would stay green through that.
    const r = await verifyFile(page('static.ss'), { custom: [{ kind: 'toString' }] });
    assert.equal(r.ok, false);
    assert.equal(r.stage, 'custom');
    assert.match(checkOf(r, 'toString').detail, /unknown check kind "toString"/);
    assert.match(r.errors.find(e => e.stage === 'custom').hint,
                 /implemented kinds:/);
    // and an unknown PROJECTION is refused by name rather than looked
    // up on Object.prototype
    await assert.rejects(
        () => verifyFile(page('slider.ss'),
                         { custom: [{ kind: 'input_changes', index: 0, by: 'toString' }] }),
        /unknown projection "toString"/);
});
