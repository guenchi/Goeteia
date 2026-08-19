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
    compile, parseNeeds, readChecks, runVerify, scenario, signature, verifyFile,
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
