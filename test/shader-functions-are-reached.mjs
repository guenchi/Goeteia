// Two questions about the GLSL this tree emits that no browser is
// needed to answer, and that nothing asked until now.
//
// ONE: HAS ANYTHING EVER DISAGREED WITH THE SIGNATURE?  emit-functions!
// in tools/shader-emit.ss wraps a function list in the smallest main
// that calls every function, and the call expression is written by hand
// with nothing comparing it against the list it is meant to reach.
//
// BE PRECISE ABOUT WHAT THAT COSTS, because the reason first written
// here was the one that file's own comment gave -- that an uncalled
// function is dead code a driver discards before reading its body --
// and it is FALSE.  Measured against the compiler this tree uses, with
// nothing calling the function: an undefined function, an undeclared
// identifier, a dimension mismatch, and an int declared from a float
// literal were all four refused.  That reading is now a row in
// test/shader-compile.mjs so it cannot quietly stop being true.
//
// So bodies are checked either way, and what a call buys is the
// SIGNATURE: a parameter list nothing calls is a parameter list nothing
// has ever disagreed with.  Transcribe a vec2 parameter as a vec3 and
// every other check here stays green.  That is a narrower claim than
// the one this cell was written under, and it is the true one.
//
// The criterion is transitive reachability, not a direct call, and that
// distinction is not theoretical: safe_unit is reached only through
// tangent_frame.  It is also "reached in at least one emitted set"
// rather than in every set that defines it -- rot_axis is spliced into
// the surface set, where nothing reaches it, and is reached in the mat
// set.  Measured, both of them, before this was written.
//
// TWO: IS IT NAMED LIKE ITS NEIGHBOURS?  Eleven of the eleven functions
// this tree emits are snake_case.  A convention at 11/11 that nothing
// checks is the shape that cost this tree three broken examples for
// seven days: 43 of 46 wrote (import (rnrs) ...) and the three outside
// the convention were exactly the three that stopped compiling.  The
// convention was not the problem; its being uncheckable was.
//
// WHY THIS IS NOT IN test/shader-compile.mjs.  That file stands down
// when no Chrome is beside the tree, and everything in it -- including
// the registration gate, which needs no browser either -- goes quiet
// with it.  Neither question here needs a GPU, so neither should be
// answerable only on a machine that has one.
import { test } from 'node:test';
import assert from 'node:assert';
import { emitAll } from '../tools/shader-emit.mjs';

const TYPE = '(?:float|vec2|vec3|vec4|mat2|mat3|mat4|bool|int|uint|void'
           + '|sampler2D|samplerCube)';

// Split a shader's text into function name -> body, by brace matching.
// A regex cannot do this part: a body contains braces, and the nesting
// is what says where it ends.
function functionBodies(src) {
    const out = new Map();
    const head = new RegExp('\\b' + TYPE + '\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*\\([^;{]*\\)\\s*\\{', 'g');
    let m;
    while ((m = head.exec(src)) !== null) {
        const open = head.lastIndex - 1;
        let depth = 0, i = open;
        for (; i < src.length; i++) {
            if (src[i] === '{') depth++;
            else if (src[i] === '}' && --depth === 0) break;
        }
        out.set(m[1], src.slice(open, i));
    }
    return out;
}

// Every name that appears in call position.  It over-approximates --
// a constructor like vec3(...) matches too -- and that direction is
// the safe one here: this set is only ever intersected with the
// functions actually defined, so a spurious name is discarded, while a
// missed name would report a live function as dead.
function callees(body) {
    return new Set([...body.matchAll(/\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)].map(x => x[1]));
}

function reachableFrom(bodies, entry) {
    const seen = new Set();
    const stack = [entry];
    while (stack.length) {
        const f = stack.pop();
        if (seen.has(f) || !bodies.has(f)) continue;
        seen.add(f);
        for (const c of callees(bodies.get(f))) if (!seen.has(c)) stack.push(c);
    }
    return seen;
}

const entries = emitAll().filter(e => !e.name.startsWith('control/'));
const defined = new Map();
const reached = new Set();
for (const e of entries) {
    for (const src of [e.vs, e.fs]) {
        if (!src) continue;
        const bodies = functionBodies(src);
        // Every set it appears in, not the last one seen.  A function
        // spliced into several sets is reached in some and not others,
        // and a red that named only one of them would send the reader
        // to a call expression that is not the one to extend.
        for (const n of bodies.keys()) {
            if (n === 'main') continue;
            if (!defined.has(n)) defined.set(n, []);
            defined.get(n).push(e.name);
        }
        for (const n of reachableFrom(bodies, 'main')) reached.add(n);
    }
}

// THE COUNT IS A ROW, because every claim below is satisfied by an
// empty set.  A parse that matched nothing -- a changed header format,
// an emitter that printed nothing, a regex that stopped matching --
// would otherwise read as "no unreached functions, no bad names".
test('the emitter produced functions to look at', () => {
    assert.ok(entries.length >= 10,
        `only ${entries.length} shaders came back from the emitter`);
    assert.ok(defined.size >= 10,
        `only ${defined.size} GLSL functions were found across ${entries.length} shaders; `
        + 'the parse is wrong, and every row below is green on an empty set');
});

test('every function this tree emits is reached from a main', () => {
    const dead = [...defined].filter(([n]) => !reached.has(n))
        .map(([n, where]) => `${n} (emitted in ${where.join(', ')})`);
    assert.deepStrictEqual(dead, [],
        'these functions are emitted but no main reaches them, so nothing has '
        + 'ever checked their signatures against a call -- their bodies are '
        + 'compiled, their parameter lists are not.  Extend the call '
        + 'expression in tools/shader-emit.ss that emit-functions! is '
        + 'given:\n  ' + dead.join('\n  '));
});

test('every function this tree emits is snake_case', () => {
    const odd = [...defined].filter(([n]) => /[A-Z]/.test(n))
        .map(([n, where]) => `${n} (in ${where.join(', ')})`);
    assert.deepStrictEqual(odd, [],
        'shader functions here are snake_case -- all of them, measured -- and '
        + 'these are not:\n  ' + odd.join('\n  '));
});

// CONTROL for both rows above, and it is the only thing that makes
// either of their greens mean anything.  A fixture with a known answer:
// kept is reached only through middle, dropped is not reached at all,
// and camelName is there for the naming row.  If the analysis cannot
// tell these apart it cannot tell anything apart, and "no unreached
// functions" would mean "this cell found no functions".
test('CONTROL the analysis separates a reached function from a dead one', () => {
    const src = [
        'float kept(float x) { return x * 2.0; }',
        'float middle(float x) { return kept(x) + 1.0; }',
        'float dropped(float x) { return x - 1.0; }',
        'float camelName(float x) { return x; }',
        'void main() { gl_FragColor = vec4(middle(1.0)); }',
    ].join('\n');
    const bodies = functionBodies(src);
    assert.deepStrictEqual([...bodies.keys()].sort(),
        ['camelName', 'dropped', 'kept', 'main', 'middle'],
        'the function-body parse did not find what is plainly there');

    const r = reachableFrom(bodies, 'main');
    assert.ok(r.has('middle'), 'a directly called function was not reached');
    assert.ok(r.has('kept'),
        'a function called only through another was not reached: the walk is '
        + 'one level deep, so it would report live functions as dead');
    assert.ok(!r.has('dropped'),
        'an uncalled function was reported as reached, so the row above cannot '
        + 'fail and proves nothing');

    assert.ok([...bodies.keys()].some(n => /[A-Z]/.test(n)),
        'the naming test does not notice an uppercase letter');
});
