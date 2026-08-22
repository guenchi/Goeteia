// rt/sexpr.mjs against the golden fixture that (igropyr sexpr) wrote.
//
// The fixture carries the authority's bytes, and it is where almost
// every expectation here comes from.  Not all of them: a few facts are
// hard-coded on purpose -- the position the authority reports for one
// astral input, and the three limits -- precisely so that a fixture
// regenerated against something wrong cannot take them with it.  This
// file never checks one of our own implementations against another -- lib/web/sexpr.ss is
// held to the same fixture by test/sexpr-golden.ss, so the three
// implementations form a triangle whose every edge is anchored on the
// Scheme original's bytes rather than on each other.
//
// Two habits this file keeps on purpose:
//
//   * the write cases build their values BY HAND rather than parsing
//     them out of the fixture first.  A codec whose reader and writer
//     share a mistake round-trips perfectly; only a value that never
//     passed through the reader can catch that.
//   * equality goes through `same` below, not deepStrictEqual, and it
//     compares numbers BY BITS -- Object.is and Number.isNaN both join
//     every NaN into one, and this fixture anchors three distinct NaN
//     bit patterns.  (This paragraph used to describe deepStrictEqual
//     and cite assert.deepEqual(42n, 42) as passing; neither is true of
//     this file, which imports node:assert/strict.)
//
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import {
    DottedList, MAX_DEPTH, MAX_SPINE, MAX_TOKEN, Ratio, SexprError, Sym,
    TO_JSON_OPTS, Vec,
    base64Decode, base64Encode, dotted, fromJSON, ratio, read, rpc,
    rpcJSON, sym,
    toJSON, write, wireSymbol,
} from '../rt/sexpr.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = JSON.parse(
    fs.readFileSync(path.join(HERE, 'sexpr-vectors.json'), 'utf8'));

const enc = new TextEncoder();
// fatal: a replacement-mode decoder would turn malformed fixture bytes
// into U+FFFD before anything compared them, so a corrupt fixture could
// read as a clean one
const dec = new TextDecoder('utf-8', { fatal: true });

// A fixture entry carries its wire either as base64 of the UTF-8 bytes
// or, when it runs to tens of kilobytes, as the rule that builds it.
// The generator verified the rule against the oracle's actual output.
function wireOf(entry, b64Field, ruleField) {
    if (entry[ruleField]) {
        const r = entry[ruleField];
        return r.prefix + r.repeat.repeat(r.count) + r.suffix;
    }
    const b64 = entry[b64Field];
    assert.ok(b64 !== undefined, `entry has neither ${b64Field} nor ${ruleField}`);
    return dec.decode(Uint8Array.from(Buffer.from(b64, 'base64')));
}
const writeWire = e => wireOf(e, 'wire_b64', 'wire_rule');
const readInput = e => wireOf(e, 'input_b64', 'input_rule');
const readCanonical = e => wireOf(e, 'canonical_b64', 'canonical_rule');

// structural equality with types, not JS coercion
function same(a, b) {
    if (a instanceof Sym) return b instanceof Sym && a.name === b.name;
    if (a instanceof Ratio)
        return b instanceof Ratio && a.num === b.num && a.den === b.den;
    if (a instanceof Vec)
        return b instanceof Vec && a.items.length === b.items.length
            && a.items.every((x, i) => same(x, b.items[i]));
    if (a instanceof DottedList)
        return b instanceof DottedList && a.items.length === b.items.length
            && a.items.every((x, i) => same(x, b.items[i])) && same(a.tail, b.tail);
    if (a instanceof Uint8Array)
        return b instanceof Uint8Array && a.length === b.length
            && a.every((x, i) => x === b[i]);
    if (Array.isArray(a))
        return Array.isArray(b) && a.length === b.length
            && a.every((x, i) => same(x, b[i]));
    if (typeof a === 'number' || typeof b === 'number') {
        if (typeof a !== typeof b) return false;
        // BY BITS. `Object.is` and `Number.isNaN` both join every NaN
        // into one, so a payload-bearing NaN and a negative NaN compared
        // EQUAL and the anchors could not tell one from the other --
        // while the native suite had compared bits all along. The wire
        // carries eight IEEE bytes; this is the value model it pins.
        const da = new DataView(new ArrayBuffer(8));
        const db = new DataView(new ArrayBuffer(8));
        da.setFloat64(0, a); db.setFloat64(0, b);
        for (let i = 0; i < 8; i++)
            if (da.getUint8(i) !== db.getUint8(i)) return false;
        return true;
    }
    if (typeof a !== typeof b) return false;       // 42n is not 42
    return a === b;
}

// ---- A. the write vectors, values built by hand --------------------

const nest = (leaf, k) => { let x = leaf; for (let i = 0; i < k; i++) x = [x]; return x; };
const fromBytes = (...b) => {
    const dv = new DataView(new ArrayBuffer(8));
    b.forEach((v, i) => dv.setUint8(i, v));
    return dv.getFloat64(0, true);
};

const HAND_BUILT = {
    'int-zero': 0n,
    'int-neg-one': -1n,
    'int-42': 42n,
    'int-2^62': 4611686018427387904n,
    'int-neg-2^90': -1237940039285380274899124224n,
    'ratio-neg-seven-halves': ratio(-7n, 2n),
    'ratio-355-113': ratio(355n, 113n),
    'string-empty': '',
    'string-quote-backslash': 'a"b\\c',
    'string-literal-newline': 'line1\nline2',
    'string-tab': 'a\tb',
    'string-unicode': '中文\u{1F600}',
    'symbol-ok': sym('ok'),
    'symbol-get-user': sym('get-user'),
    'symbol-punctuation': sym('a*-+<=>?!b'),
    'bool-true': true,
    'bool-false': false,
    'empty-list': [],
    'list-proper': [1n, 2n, 3n],
    'list-dotted': new DottedList([1n], 2n),
    'list-dotted-tail': new DottedList([1n, 2n], 3n),
    'list-alist': [new DottedList([sym('a')], 1n), new DottedList([sym('b')], 2n)],
    'list-nested': [1n, [2n, [3n, 4n]], 5n],
    'list-mixed': [sym('get-user'), 42n, 'x', true],
    'vector-empty': new Vec([]),
    'vector-nested-dotted': new Vec([1n, new DottedList([2n], 3n)]),
    'bytevector-empty': new Uint8Array([]),
    'bytevector-0-1-255': new Uint8Array([0, 1, 255]),
    'bytevector-32': new Uint8Array(Array.from({ length: 32 }, (_, k) => (k * 7) & 0xff)),
    'flonum-1.5': 1.5,
    'flonum-1.0': 1.0,
    'flonum-0.1': 0.1,
    'flonum-inf': Infinity,
    'flonum-neg-inf': -Infinity,
    'flonum-nan': NaN,
    'flonum-neg-zero': -0,
    'flonum-pos-zero': 0,
    'flonum-min-subnormal': fromBytes(1, 0, 0, 0, 0, 0, 0, 0),
    'flonum-min-normal': fromBytes(0, 0, 0, 0, 0, 0, 16, 0),
    'flonum-max': fromBytes(255, 255, 255, 255, 255, 255, 239, 127),
    'flonum-nan-payload': fromBytes(1, 0, 0, 0, 0, 0, 248, 127),
    'flonum-nan-negative': fromBytes(0, 0, 0, 0, 0, 0, 248, 255),
    'deep-63': nest([], 62),
    'deep-64-atom': nest(1n, 64),
    'string-64k': 'a'.repeat(65600),
    'symbol-token-cap': sym('a'.repeat(65536)),   // the authority's cap
    'list-flat-long': Array.from({ length: 3000 }, (_, k) => BigInt(2999 - k)),
    'bytevector-64k': new Uint8Array(70000).fill(7),
};

test('every golden write vector is produced byte for byte', () => {
    assert.equal(Object.keys(HAND_BUILT).length, FIXTURE.write.length,
        'the fixture and the hand-built table have drifted apart');
    for (const e of FIXTURE.write) {
        assert.ok(e.name in HAND_BUILT, `no hand-built value for "${e.name}"`);
        const expected = writeWire(e);
        const got = write(HAND_BUILT[e.name]);
        assert.equal(got, expected, `write mismatch for ${e.name}`);
        // ...and against the fixture's RAW BYTES, not against the same
        // string re-encoded: encoding two already-equal strings cannot
        // fail, so that comparison proved nothing about the wire
        if (e.wire_b64) {
            assert.deepStrictEqual(
                Array.from(enc.encode(got)),
                Array.from(Uint8Array.from(Buffer.from(e.wire_b64, 'base64'))),
                `byte mismatch for ${e.name}`);
        }
    }
});

test('every golden write vector parses back to the value it came from', () => {
    for (const e of FIXTURE.write) {
        const wire = writeWire(e);
        const parsed = read(wire);
        assert.ok(same(parsed, HAND_BUILT[e.name]),
            `parse of ${e.name} did not return the original value`);
        assert.equal(write(parsed), wire, `${e.name} is not a fixed point`);
    }
});

test('the flonum cases keep their exact bits, both zeros and both NaNs', () => {
    assert.ok(Object.is(read(write(-0)), -0), '-0 came back as +0');
    assert.ok(Object.is(read(write(0)), 0));
    assert.ok(Number.isNaN(read(write(NaN))));
    // a NaN with a payload and a negative NaN are distinct bit patterns
    // that decimal text cannot carry; #f8 must round-trip the BYTES
    for (const name of ['flonum-nan-payload', 'flonum-nan-negative']) {
        const e = FIXTURE.write.find(x => x.name === name);
        const wire = writeWire(e);
        assert.equal(write(read(wire)), wire, `${name} lost its bit pattern`);
    }
    assert.equal(read(write(Infinity)), Infinity);
    assert.equal(read(write(-Infinity)), -Infinity);
});

// ---- B. the read side, adjudicated by the oracle -------------------

test('the oracle\'s accept set is accepted, with the same canonical form', () => {
    let rewritten = 0, unwritable = 0;
    for (const e of FIXTURE.read) {
        if (!e.accepted) continue;
        const v = read(readInput(e));
        if (e.rewritable) {
            assert.equal(write(v), readCanonical(e),
                `canonical rewrite differs for ${e.name}`);
            rewritten++;
        } else {
            // the authority parses it but will not write it again (a
            // symbol named "+5"): both halves have to agree, or this
            // side would emit a datum the authority refuses to produce
            assert.throws(() => write(v), SexprError,
                `${e.name}: the authority refuses to re-write this, we do not`);
            unwritable++;
        }
    }
    // NOT asserted here: `rewritten + unwritable === <accepted count>`.
    // The loop increments exactly one of the two per accepted entry, so
    // that equation is algebraically guaranteed and cannot fail -- and
    // its comment used to claim it stopped an entry being deleted from
    // the fixture, which it never did (a deletion lowers both sides).
    // What actually catches a deletion is the generator's own count,
    // asserted in "the fixture is whole, named and self-consistent".
    assert.ok(unwritable >= 2, 'no probe covers "parses but cannot be written"');
});

test('the oracle\'s reject set is rejected at the SAME position', () => {
    let checked = 0;
    for (const e of FIXTURE.read) {
        if (e.accepted) continue;
        let err = null;
        try { read(readInput(e)); } catch (x) { err = x; }
        assert.ok(err, `${e.name}: accepted an input the authority refuses`);
        assert.ok(err instanceof SexprError,
            `${e.name}: threw ${err && err.name}, not SexprError`);
        // the oracle records "message @position"; an implementation
        // that reported 0 everywhere would satisfy "is a number"
        const at = Number(e.error.slice(e.error.lastIndexOf('@') + 1));
        assert.equal(err.position, at,
            `${e.name}: position ${err.position}, authority says ${at}`);
        checked++;
    }
    // (no `checked === <rejected count>` assertion: the counter rises
    // once per rejected entry, so it cannot disagree.  Deletions are
    // caught by the generator's recorded counts.)
});

test('positions are counted in code points, as the authority counts them', () => {
    // the sweep above covers the verdict; this names ONE input where a
    // UTF-16 port would be off by exactly one, and pins the number the
    // authority reports for it -- which the sweep does not, since it
    // compares our position against the fixture's whatever both say
    const e = FIXTURE.read.find(x => x.name === 'read-astral-trailing');
    assert.ok(!e.accepted);
    assert.equal(Number(e.error.slice(e.error.lastIndexOf('@') + 1)), 3);
    assert.throws(() => read(readInput(e)), x => x.position === 3);
    // the literal 3 is the authority's own number for this input; it can
    // fail if the fixture's position changes while our reader keeps
    // agreeing with it, which the sweep by itself cannot notice
});

test('the base64 boundary is the authority\'s, not a plausible one', () => {
    // these are one character apart and land on both sides of the
    // "leftover bits must be zero" rule; a decoder that skips the check
    // passes three of them, and atob passes different ones again
    assert.deepStrictEqual(Array.from(read('#vu8"A"')), []);
    assert.deepStrictEqual(Array.from(read('#vu8"===="')), []);
    assert.deepStrictEqual(Array.from(read('#vu8"/w=="')), [255]);
    assert.deepStrictEqual(Array.from(read('#vu8"A=A="')), [0]);
    assert.throws(() => read('#vu8"AB"'), SexprError);
    assert.throws(() => read('#vu8"AR=="'), SexprError);
});

test('#f8 is checked by DECODED LENGTH, not by character count', () => {
    // twelve characters that decode to nine bytes, and a padded payload
    // that decodes to eight: a character count accepts the first, which
    // is the dangerous direction.
    assert.throws(() => read('#f8"AAAAAAAAAAAA"'), SexprError);
    assert.equal(read('#f8"AAAAAAAAAAA="'), 0);
    // and both of those are twelve characters long, so a `length === 12`
    // gate would pass this pair while refusing a legal payload.  These
    // are thirteen and fourteen characters and decode to eight bytes:
    assert.equal(read('#f8"=AAAAAAAAAAA="'), 0);
    assert.equal(read('#f8"==AAAAAAAAAAA="'), 0);
});

test('the number grammar keeps the shapes the authority gives it', () => {
    assert.strictEqual(read('007'), 7n);
    assert.strictEqual(read('-007'), -7n);
    assert.strictEqual(read('0/7'), 0n);
    assert.strictEqual(read('4/2'), 2n);
    const r = read('2/4');
    assert.ok(r instanceof Ratio && r.num === 1n && r.den === 2n);
    assert.ok(read('+5') instanceof Sym);
    for (const bad of ['1/-2', '1//2', '1/0', '1e3', '1.5', '0x10', '12abc'])
        assert.throws(() => read(bad), SexprError, `${bad} should not read`);
});

test('a dotted tail that is a list is the same datum as the longer list', () => {
    assert.deepStrictEqual(read('(a . ())'), [sym('a')]);
    assert.equal(write(read('(a . (b c))')), '(a b c)');
    assert.equal(write(read('(a . (b . c))')), '(a b . c)');
    // and the constructor refuses the shape it would have to fold
    assert.throws(() => new DottedList([1n], []), TypeError);
    assert.throws(() => new DottedList([1n], [2n]), TypeError);
    assert.throws(() => new DottedList([], 1n), TypeError);
    assert.deepStrictEqual(dotted([1n], []), [1n]);
    assert.deepStrictEqual(dotted([1n], [2n]), [1n, 2n]);
    // a hole is not a datum, and an inherited index is not this array's
    // data -- dotted() folds arrays, so it has to ask the same question
    // the rest of the module does
    assert.throws(() => dotted([1n], Array(1)), /hole/);
    assert.throws(() => dotted(Array(1), 2n), /hole/);
    const saved = Object.getOwnPropertyDescriptor(Array.prototype, 0);
    Array.prototype[0] = 99n;
    try {
        assert.throws(() => dotted([1n], Array(1)), /hole/,
            'an inherited index became payload');
    } finally {
        delete Array.prototype[0];
        if (saved) Object.defineProperty(Array.prototype, 0, saved);
    }
});

test('the ratio policy is wide in and narrow out, in all four cases', () => {
    // wide in: an unnormalized ratio is accepted and normalized, and
    // what reaches the wire is the canonical form -- these are BYTE
    // assertions because "2/4" on the wire is a datum the authority
    // would never produce for this value
    // FOUR, and they are the four sign combinations -- count them:
    // (+,+) (+,-) (-,-) and (-,+).  The last one used to be missing,
    // and its absence was invisible because the other three are not
    // interchangeable with it: `(-,+)` is the only combination whose
    // numerator is negative WITHOUT the `d < 0n` flip running, so a
    // change to that flip's condition can break it alone.  Measured:
    // widening the flip to `d < 0n || n < 0n` leaves all three of the
    // old rows green and reddens five OTHER assertions in this file --
    // the property was held, by names that do not claim it, while the
    // name that did claim it exercised three of its four cases.
    assert.equal(write(new Ratio(2n, 4n)), '1/2');
    assert.equal(write(new Ratio(1n, -2n)), '-1/2');
    assert.equal(write(new Ratio(-2n, -4n)), '1/2');
    assert.equal(write(new Ratio(-2n, 4n)), '-1/2');
    // narrow out: a ratio that reduces to a whole number is refused
    // rather than silently changing type on the far side
    assert.throws(() => new Ratio(4n, 2n), /reduces to the integer 2/);
    assert.throws(() => new Ratio(0n, 7n), /reduces to the integer 0/);
    // (the factory's collapse is asserted once, in "a ratio that
    // reduces to an integer is an integer" -- repeating it here was a
    // second copy of one assertion, not a second assertion)
    // and a zero denominator is not a number anywhere
    assert.throws(() => new Ratio(1n, 0n), /zero denominator/);
    assert.throws(() => ratio(1n, 0n), /zero denominator/);
});

test('a ratio that reduces to an integer is an integer', () => {
    assert.strictEqual(ratio(4n, 2n), 2n);
    assert.strictEqual(ratio(0n, 7n), 0n);
    const r = ratio(-2n, -4n);
    assert.ok(r instanceof Ratio && r.num === 1n && r.den === 2n);
    assert.throws(() => ratio(1n, 0n), RangeError);
    assert.throws(() => new Ratio(4n, 2n), RangeError);
    // sign lives on the numerator
    const s = ratio(1n, -2n);
    assert.ok(s.num === -1n && s.den === 2n);
});

// ---- the writer's refusal set, name by name ------------------------

test('the writer agrees with the authority on every symbol name', () => {
    let rejected = 0, accepted = 0;
    for (const e of FIXTURE.write_reject) {
        if (e.rejected) {
            assert.equal(wireSymbol(e.sym), false,
                `we would write symbol ${JSON.stringify(e.sym)}, which the `
                + 'authority refuses');
            assert.throws(() => write(sym(e.sym)), SexprError);
            rejected++;
        } else {
            assert.equal(wireSymbol(e.sym), true,
                `we refuse symbol ${JSON.stringify(e.sym)}, which the authority writes`);
            assert.equal(write(sym(e.sym)), e.sym === '' ? '' : writeSymText(e));
            accepted++;
        }
    }
    // (no `rejected + accepted === <length>` assertion: one of the two
    // rises per entry, so it cannot disagree.  Deletions are caught by
    // the generator's recorded counts.)
});
function writeSymText(e) {
    return dec.decode(Uint8Array.from(Buffer.from(e.wire_b64, 'base64')));
}

test('no name is written that cannot be read back', () => {
    // The generator measures this: every name the authority writes is
    // fed back to its own reader and compared.  An entry marked here
    // would mean the authority emits a datum nobody can read -- it did,
    // for five names, until the fix this fixture was regenerated
    // against.  Asserting the empty set keeps that closed rather than
    // trusting it to stay closed.
    const marked = FIXTURE.write_reject.filter(e => e.divergence);
    assert.deepStrictEqual(marked.map(e => e.sym), [],
        'the authority writes a name its own reader refuses again');
    // and our writer agrees with it name for name, which the test above
    // checks; here are the five names that used to be the divergence
    for (const name of ['0x10', '12abc', '1/-2', '1//2', '1/0']) {
        assert.equal(wireSymbol(name), false);
        assert.throws(() => read(name), SexprError);
    }
});

// The authority's constants, written out rather than imported from the
// module under test.  Importing MAX_TOKEN would make every boundary
// assertion agree with whatever the module currently says -- change the
// constant to 100 and the suite still passes, having tested the wrong
// boundary and confirmed itself.  These numbers come from
// 01-igropyr/sexpr.sc (default-max-token, default-max-depth) and from
// the writer's spine guard there.
const AUTHORITY_TOKEN_CAP = 65536;
const AUTHORITY_DEPTH_LIMIT = 64;
const AUTHORITY_SPINE_CAP = 1000000;

test('the module agrees with the authority about its own limits', () => {
    // and the module's constants are pinned against them, so a change
    // to one is a failure rather than a silently moved goalpost
    assert.equal(MAX_TOKEN, AUTHORITY_TOKEN_CAP);
    assert.equal(MAX_SPINE, AUTHORITY_SPINE_CAP);
    assert.equal(MAX_DEPTH, AUTHORITY_DEPTH_LIMIT);
});

test('the token cap bounds tokens in BOTH directions, and nothing else', () => {
    // What the cap bounds is one TOKEN -- a symbol name or a printed
    // numeral -- and the writer now refuses what the reader would,
    // rather than emitting a datum that comes back as "token too long".
    assert.equal(read('a'.repeat(AUTHORITY_TOKEN_CAP)).name.length, AUTHORITY_TOKEN_CAP);
    assert.throws(() => read('a'.repeat(AUTHORITY_TOKEN_CAP + 1)), SexprError);
    assert.equal(write(sym('a'.repeat(AUTHORITY_TOKEN_CAP))).length, AUTHORITY_TOKEN_CAP);
    assert.throws(() => write(sym('a'.repeat(AUTHORITY_TOKEN_CAP + 1))), SexprError);
    // a numeral is a token too: an integer whose decimal text is longer
    // than the cap cannot go out
    const big = BigInt('1'.repeat(AUTHORITY_TOKEN_CAP));
    assert.equal(write(big).length, AUTHORITY_TOKEN_CAP);
    assert.throws(() => write(big * 10n), /token too long/);
    // and a ratio is measured WHOLE -- two halves that each fit are
    // still one token to the reader
    const half = BigInt('1'.repeat(40000));
    assert.throws(() => write(ratio(half, half + 2n)), /token too long/);
    // what is NOT a token is not bounded by THIS cap.  The samples run
    // past 65536 on purpose: a regression that applied the token cap to
    // a list's length or a string's length would pass at 3000.
    assert.equal(read(write('a'.repeat(70000))).length, 70000);
    assert.equal(read(write(new Uint8Array(70000).fill(7))).length, 70000);
    assert.equal(read(write(Array.from({ length: 70000 }, () => 1n))).length, 70000);
    // a list IS bounded, but by the spine cap, which is elsewhere
    // BOTH sides of the boundary, and the dotted branch: asserting only
    // that 1,000,002 is refused would pass an off-by-one that refused
    // 1,000,001, and would not notice the dotted check being deleted
    const spineOk = Array.from({ length: AUTHORITY_SPINE_CAP + 1 }, () => 1n);
    assert.equal(read(write(spineOk)).length, AUTHORITY_SPINE_CAP + 1);
    assert.throws(() => write([...spineOk, 1n]), /list too long/);
    assert.throws(() => write(new DottedList(spineOk.concat([1n]), 2n)),
                  /list too long/);
    assert.equal(typeof write(new DottedList(spineOk, 2n)), 'string');
});

test('maxDepth may narrow what this side accepts, never widen it', () => {
    // A deeper limit would let this writer emit a datum the peer's
    // reader refuses -- the one promise this module makes about its
    // output.  Infinity and NaN would also disable the guard that
    // stops a cycle.
    let deep = 1n;
    for (let k = 0; k < 65; k++) deep = [deep];
    assert.throws(() => write(deep, { maxDepth: 100 }), RangeError);
    assert.throws(() => read('1', { maxDepth: Infinity }), RangeError);
    assert.throws(() => read('1', { maxDepth: NaN }), RangeError);
    assert.throws(() => read('1', { maxDepth: -1 }), RangeError);
    assert.throws(() => read('1', { maxDepth: 1.5 }), RangeError);
    // ...and a SMALLER limit is legitimate: it only narrows this side
    assert.deepStrictEqual(read('((1))', { maxDepth: 8 }), [[1n]]);
    assert.throws(() => read('((1))', { maxDepth: 1 }), SexprError);
    // the default still reaches the authority's own boundary
    let ok = 1n;
    for (let k = 0; k < 64; k++) ok = [ok];
    assert.equal(typeof write(ok), 'string');
});

test('a string that has no UTF-8 encoding does not go out', () => {
    // a lone surrogate survives as a JS string and becomes U+FFFD the
    // moment it is encoded for the wire: the bytes sent would not be
    // the value the writer accepted
    assert.throws(() => write('a\uD800b'), /unpaired surrogate/);
    assert.throws(() => write('\uDC00'), /unpaired surrogate/);
    assert.throws(() => write([sym('tag'), 'x\uD83D']), /unpaired surrogate/);
    // a properly paired one is ordinary text
    assert.equal(write('a\u{1F600}b'), '"a\u{1F600}b"');
});

test('the writer refuses everything outside the whitelist, by name', () => {
    for (const [what, value] of [['null', null], ['undefined', undefined],
                                 ['plain object', { a: 1 }], ['function', () => {}],
                                 ['Int8Array', new Int8Array([1])],
                                 ['Map', new Map()]])
        assert.throws(() => write(value), SexprError, `wrote a ${what}`);
    const cyc = []; cyc.push(cyc);
    assert.throws(() => write(cyc), SexprError);
});

// ---- C. the JSON view ----------------------------------------------

test('toJSON maps every rule it can, in both directions', () => {
    assert.equal(toJSON(sym('get-user')), 'get-user');
    assert.equal(toJSON('text'), 'text');
    assert.equal(toJSON(true), true);
    assert.equal(toJSON(42n), 42);
    assert.equal(toJSON(9007199254740991n), 9007199254740991);
    assert.equal(toJSON(-9007199254740991n), -9007199254740991);
    assert.equal(toJSON(1.5), 1.5);
    assert.deepStrictEqual(toJSON([1n, 2n]), [1, 2]);
    assert.deepStrictEqual(toJSON(new Vec([1n])), [1]);
    assert.deepStrictEqual(toJSON([]), [], 'an empty list stays an array');
});

test('toJSON refuses every loss it cannot make silently', () => {
    assert.throws(() => toJSON(9007199254740992n), /safe range/);
    assert.throws(() => toJSON(-9007199254740992n), /safe range/);
    assert.equal(toJSON(9007199254740992n, { bigint: 'string' }), '9007199254740992');
    assert.throws(() => toJSON(ratio(1n, 3n)), /ratio/);
    assert.equal(toJSON(ratio(1n, 4n), { ratio: 'number' }), 0.25);
    // the opt-in accepts loss of EXACTNESS, not loss of the value: a
    // ratio with no finite double is still refused, as the number
    // branch beside it refuses Infinity
    assert.throws(() => toJSON(new Ratio(10n ** 400n, 3n), { ratio: 'number' }),
                  /no finite double/);
    // ...but a ratio whose OPERANDS overflow while its value does not
    // must still convert: dividing the two converted operands gives
    // Infinity/Infinity = NaN and refuses a ratio worth exactly 1
    const p = 10n ** 400n;
    assert.equal(toJSON(new Ratio(p, p + 1n), { ratio: 'number' }), 1);
    // (not p*2/p -- that reduces to the integer 2 and the constructor
    // refuses it by policy; this one stays a ratio)
    assert.ok(Math.abs(toJSON(new Ratio(p * 2n, p + 1n), { ratio: 'number' }) - 2)
              < 1e-9);
    assert.equal(toJSON(ratio(1n, 3n), { ratio: 'number' }), 1 / 3);
    // ...and one far BELOW a fixed fractional step: a 2^-64 scale
    // rounded every such value to zero
    assert.equal(toJSON(new Ratio(1n, (1n << 100n) + 1n), { ratio: 'number' }),
                 7.888609052210118e-31);
    assert.ok(toJSON(new Ratio(1n, 1n << 200n), { ratio: 'number' }) > 0);
    assert.throws(() => toJSON(NaN), /NaN/);
    assert.throws(() => toJSON(Infinity), /Infinity/);
    assert.throws(() => toJSON(new Uint8Array([1])), /bytevector/);
    assert.equal(toJSON(new Uint8Array([255]), { bytes: 'base64' }), '/w==');
    assert.throws(() => toJSON(new DottedList([1n], 2n)), /dotted/);
    // and the refusals reach into nested positions too
    assert.throws(() => toJSON([1n, [new Uint8Array([1])]]), /bytevector/);
    // a cycle: fromJSON reports one, and this direction must too rather
    // than running the host out of stack
    const cyc = [1n]; cyc.push(cyc);
    assert.throws(() => toJSON(cyc), /cycle/);
    // and one that closes through two arrays rather than one, which a
    // depth counter would eventually stop but only after a long climb
    const a = [], b = [a];
    a.push(b);
    assert.throws(() => toJSON(a), /cycle/);
    assert.throws(() => toJSON({ }), /no JSON representation|typeof/);
});

test('the alist rule produces a null-prototype object and nothing surprising', () => {
    const alist = [new DottedList([sym('a')], 1n), new DottedList([sym('b')], 'x')];
    const o = toJSON(alist);
    assert.equal(Object.getPrototypeOf(o), null,
        'an alist key named __proto__ must be data, not a prototype reach');
    assert.deepStrictEqual({ ...o }, { a: 1, b: 'x' });
    // keys that mean something on Object.prototype are just keys
    for (const k of ['__proto__', 'constructor', 'toString']) {
        const one = toJSON([new DottedList([sym(k)], 7n)]);
        assert.equal(one[k], 7);
        assert.equal(Object.keys(one).length, 1);
    }
    // a duplicate key drops half the payload; a falsy first value would
    // hide from a truthiness check
    assert.throws(() => toJSON([new DottedList([sym('a')], false),
                                new DottedList([sym('a')], true)]), /duplicate key/);
    assert.throws(() => toJSON([new DottedList([sym('a')], 0n),
                                new DottedList([sym('a')], 1n)]), /duplicate key/);
    // one non-pair element and the alist rule does not apply
    assert.throws(() => toJSON([new DottedList([sym('a')], 1n), 2n]), /dotted/);
});

test('a mistyped option is refused, not ignored', () => {
    // Most option typos fail closed -- {bytes:'b64'} leaves the loss
    // refused.  {alists:false} did not: the alist rule stayed on and
    // the SHAPE of the result changed silently, which is the failure
    // this codec refuses everywhere else.
    const alist = [new DottedList([sym('a')], 1n)];
    assert.throws(() => toJSON(alist, { alists: false }), /unknown option "alists"/);
    assert.throws(() => toJSON(1n, { bigints: 'string' }), /unknown option/);
    assert.throws(() => toJSON(1n, { bigint: 'string', nope: 1 }), /unknown option "nope"/);
    // ...and a wrong VALUE is refused too, which matters more than the
    // key: `{alist:'false'}` and `{alist:0}` are not false, and they
    // used to leave the rule ON and change the result's shape
    assert.throws(() => toJSON(alist, { alist: 'false' }), /takes true or false/);
    assert.throws(() => toJSON(alist, { alist: 0 }), /takes true or false/);
    assert.throws(() => toJSON(alist, { alist: null }), /takes true or false/);
    assert.throws(() => toJSON(1n, { bigint: 'str' }), /takes "string"/);
    assert.throws(() => toJSON(new Uint8Array([1]), { bytes: 'b64' }), /takes "base64"/);
    // the bag itself has to be a PLAIN object -- an array, a Map, a
    // Date or a boxed primitive is not an options bag
    assert.throws(() => toJSON(1n, 7), /options object/);
    assert.throws(() => toJSON(1n, null), /options object/);
    assert.throws(() => toJSON(1n, []), /plain options object/);
    assert.throws(() => toJSON(1n, new Map()), /plain options object/);
    assert.throws(() => toJSON(1n, new Date()), /plain options object/);
    assert.throws(() => toJSON(1n, { [Symbol('x')]: 1 }), /named with strings/);
    // an inherited option would be read by the consumer and never seen
    // by the check
    assert.throws(() => toJSON(1n, Object.create({ bigint: 'string' })),
                  /inherited/);
    // and an accessor cannot answer one thing to the check and another
    // to the consumer: the validated values are snapshotted
    let calls = 0;
    const shifty = { get alist() { return calls++ ? 0 : false; } };
    const alistPairs = [new DottedList([sym('a')], 1n)];
    assert.throws(() => toJSON(alistPairs, shifty), /dotted|takes true or false/);
    // read and write have the same surface
    assert.throws(() => read('((1))', { maxdepth: 0 }), /unknown option "maxdepth"/);
    assert.throws(() => read('1', 7), /options object/);
    assert.throws(() => write([[1n]], { maxdepth: 0 }), /unknown option "maxdepth"/);
    // and the whitelist cannot be widened from outside
    assert.ok(Object.isFrozen(TO_JSON_OPTS));
    // the real names still work
    assert.deepStrictEqual({ ...toJSON(alist) }, { a: 1 });
    assert.throws(() => toJSON(alist, { alist: false }), /dotted/);
});

test('fromJSON takes one argument; its cycle set is not a parameter', () => {
    // handing the internal set something else used to fail with
    // "seen.has is not a function" from three frames down
    assert.throws(() => fromJSON([1], 'junk'), /takes one argument/);
    assert.throws(() => fromJSON([1], {}), /takes one argument/);
    assert.equal(write(fromJSON([1])), '(1)');
});

// (no "turning the alist rule off" test: the assertion it made is the
// same call on an equivalent value as the one in "the alist rule
// produces a null-prototype object and nothing surprising", so it could
// not fail on its own.)

// ---- D. fromJSON ---------------------------------------------------

test('a safe integer becomes exact, except -0, which keeps its sign', () => {
    // the red evidence for the whole exactness decision
    assert.equal(write(fromJSON(42)), '42');
    assert.equal(write(fromJSON(-1)), '-1');
    assert.equal(typeof fromJSON(42), 'bigint');
    assert.match(write(fromJSON(1.5)), /^#f8"/);
    assert.equal(typeof fromJSON(1.5), 'number');
    assert.match(write(fromJSON(9007199254740993.5)), /^#f8"/);
    // -0 IS recoverable through JSON (JSON.parse("-0") is -0) and the
    // wire carries a signed zero bit-exactly, so it crosses as a flonum
    // rather than collapsing into the exact 0 that BigInt(-0) gives
    assert.ok(Object.is(fromJSON(-0), -0));
    assert.match(write(fromJSON(-0)), /^#f8"/);
    assert.ok(Object.is(read(write(fromJSON(-0))), -0));
});

test('fromJSON refuses what has no datum, at conversion time', () => {
    assert.throws(() => fromJSON(null), /null has no wire representation/);
    assert.throws(() => fromJSON(undefined), /undefined/);
    assert.throws(() => fromJSON(() => {}), /function/);
    assert.throws(() => fromJSON(Symbol('x')), /JS symbol/);
    assert.throws(() => fromJSON(NaN), /cannot cross/);
    assert.throws(() => fromJSON(Infinity), /cannot cross/);
    // a key that could not be written names ITSELF here; by write() time
    // the key is gone and only "symbol not wire-safe" would be left
    assert.throws(() => fromJSON({ 12: 1 }), /key "12"/);
    assert.throws(() => fromJSON({ '.': 1 }), /key "\."/);
    assert.throws(() => fromJSON({ '1.5': 1 }), /key "1\.5"/);
    // a symbol-keyed property is invisible to Object.entries: it would
    // vanish from the payload rather than be refused
    assert.throws(() => fromJSON({ [Symbol('k')]: 1 }), /symbol key/);
    assert.throws(() => fromJSON({ a: 1, [Symbol('k')]: 2 }), /symbol key/);
    // holes and cycles
    assert.throws(() => fromJSON([1, , 3]), /hole/);
    // and a hole that OPENS while the array is being read: validating
    // first and walking again would see index 1 as own data in the
    // first pass and read Array.prototype[1] in the second
    const saved = Object.getOwnPropertyDescriptor(Array.prototype, 1);
    Array.prototype[1] = 99;
    try {
        const trap = [0, 0];
        Object.defineProperty(trap, 0, {
            configurable: true, enumerable: true,
            get() { delete trap[1]; return 1; },
        });
        assert.throws(() => fromJSON(trap), /hole/,
            'an element deleted mid-walk let an inherited value through');
    } finally {
        delete Array.prototype[1];
        if (saved) Object.defineProperty(Array.prototype, 1, saved);
    }
    // the OBJECT path has the same two-pass hazard: read the keys, then
    // read the values, and a getter fired by the first key can delete
    // the second -- after which the value read is an inherited one
    const savedProto = Object.getOwnPropertyDescriptor(Object.prototype, 'b');
    Object.prototype.b = 'inherited';
    try {
        const trap = {};
        Object.defineProperty(trap, 'a', {
            configurable: true, enumerable: true,
            get() { delete trap.b; return 1; },
        });
        trap.b = 2;
        const v = fromJSON(trap);
        // whatever it does, it must not have taken the prototype's value
        const written = write(v);
        assert.ok(!written.includes('inherited'),
            `an inherited property became payload: ${written}`);
    } finally {
        delete Object.prototype.b;
        if (savedProto) Object.defineProperty(Object.prototype, 'b', savedProto);
    }
    const cyc = {}; cyc.self = cyc;
    assert.throws(() => fromJSON(cyc), /cycle/);
    const cycArr = []; cycArr.push(cycArr);
    assert.throws(() => fromJSON(cycArr), /cycle/);
});

test('fromJSON takes own enumerable keys, in order', () => {
    const base = Object.create({ inherited: 1 });
    base.own = 2;
    const v = fromJSON(base);
    assert.equal(v.length, 1, 'an inherited property is not this object\'s data');
    assert.equal(write(v), '((own . 2))');
    assert.equal(write(fromJSON({ b: 1, a: 2 })), '((b . 1) (a . 2))');
});

test('the object surface is plain objects only, and {} is not a round trip', () => {
    // a Map, Set, Date, RegExp or boxed primitive has no own enumerable
    // string keys, so Object.entries would answer [] and the payload
    // would vanish instead of being refused
    for (const [what, v] of [['Map', new Map([['a', 1]])], ['Set', new Set([1])],
                             ['Date', new Date()], ['RegExp', /x/],
                             ['boxed', new Number(5)]])
        assert.throws(() => fromJSON(v), /no wire representation/, `${what} passed`);
    // an ordinary object with an ordinary prototype is still data
    assert.equal(write(fromJSON(Object.assign(Object.create({ inh: 1 }), { own: 2 }))),
                 '((own . 2))');
    // and the empty object is where the round trip genuinely stops:
    // the wire has no empty alist distinct from the empty list
    assert.equal(write(fromJSON({})), '()');
    assert.deepStrictEqual(toJSON(read('()')), []);
});

test('the exotic-object check reads internal slots, not a tag', () => {
    // Symbol.toStringTag is the caller's to set: a Map wearing 'Object'
    // would have passed a toString-based check and lost its entries
    const tagged = new Map([['a', 1]]);
    Object.defineProperty(tagged, Symbol.toStringTag, { value: 'Object' });
    assert.throws(() => fromJSON(tagged), /no wire representation for Map/);
    class Sneaky extends Map { get [Symbol.toStringTag]() { return 'Object'; } }
    assert.throws(() => fromJSON(new Sneaky([['a', 1]])), /no wire representation/);
    // ...and an ordinary object wearing someone else's tag is still data
    const plain = { a: 1 };
    Object.defineProperty(plain, Symbol.toStringTag, { value: 'Map' });
    assert.equal(write(fromJSON(plain)), '((a . 1))');
});

test('the base64 helpers refuse what they cannot represent', () => {
    // a hole is not a zero byte, and an inherited index is not data
    assert.throws(() => base64Encode(Array(1)), /hole/);
    const saved = Object.getOwnPropertyDescriptor(Array.prototype, 0);
    Array.prototype[0] = 255;
    try {
        assert.throws(() => base64Encode(Array(1)), /hole/,
                      'an inherited index became a byte');
    } finally {
        delete Array.prototype[0];
        if (saved) Object.defineProperty(Array.prototype, 0, saved);
    }
    assert.throws(() => base64Encode([256]), /wants bytes|array of bytes/);
    assert.throws(() => base64Encode([-1]), /wants bytes|array of bytes/);
    assert.throws(() => base64Encode('AAA'), /Uint8Array/);
    assert.throws(() => base64Decode(123, () => null), /wants a string/);
    assert.throws(() => base64Decode('AA'), /failure callback/);
    // and the ordinary uses still work
    assert.equal(base64Encode(new Uint8Array([255])), '/w==');
    assert.equal(base64Encode([0, 1, 255]), 'AAH/');
    assert.deepStrictEqual(Array.from(base64Decode('AAH/', () => null)),
                           [0, 1, 255]);
});

test('a scalar-valued payload survives the whole round trip unchanged', () => {
    const payload = { id: 42, name: 'ada', ok: true, ratio: 'n/a' };
    assert.deepStrictEqual(
        JSON.parse(JSON.stringify(toJSON(read(write(fromJSON(payload)))))),
        payload);
});

test('a list-valued key flattens, because the wire cannot tell them apart', () => {
    // (k . (1 2)) IS (k 1 2) in this grammar -- there is no third datum
    // for "the pair whose tail happens to be a list".  So an object
    // whose value is an array serializes to a proper list and reads
    // back as one, and toJSON no longer sees an alist.  Pinned here
    // because the alternative is a reader somewhere quietly getting a
    // different shape than the writer sent.
    assert.equal(write(fromJSON({ tags: ['x', 'y'] })), '((tags "x" "y"))');
    assert.deepStrictEqual(toJSON(read('((tags "x" "y"))')), [['tags', 'x', 'y']]);
    // scalar values keep the pair, and with it the object view
    assert.equal(write(fromJSON({ id: 42 })), '((id . 42))');
    assert.deepStrictEqual({ ...toJSON(read('((id . 42))')) }, { id: 42 });
});

test('precise values may be mixed into a JSON-shaped payload', () => {
    const v = fromJSON({ blob: new Uint8Array([1, 2]), n: 7, r: ratio(1n, 3n) });
    const wire = write(v);
    assert.match(wire, /#vu8"/);
    assert.match(wire, /1\/3/);
    const back = toJSON(read(wire), { bytes: 'base64', ratio: 'number' });
    assert.equal(back.n, 7);
    assert.equal(back.blob, 'AQI=');
});

// ---- E. rpc, at the byte level -------------------------------------

const withFetch = async (impl, body) => {
    const saved = globalThis.fetch;
    globalThis.fetch = impl;
    try { return await body(); } finally { globalThis.fetch = saved; }
};
const sexprResponse = (text, init = {}) =>
    new Response(enc.encode(text),
                 { status: 200, headers: { 'Content-Type': 'application/sexpr' },
                   ...init });

test('rpc sends exactly the datum, as UTF-8 bytes', async () => {
    let seen = null;
    await withFetch(async (url, init) => {
        seen = { url, init, bytes: new Uint8Array(await new Request(url, init).arrayBuffer()) };
        return sexprResponse('(ok 1)');
    }, async () => {
        const v = await rpc('https://example.test/api', 'note',
                            '中文\u{1F600}\nline');
        const expected = enc.encode('(note "中文\u{1F600}\nline")');
        assert.deepStrictEqual(Array.from(seen.bytes), Array.from(expected));
        assert.equal(seen.init.method, 'POST');
        assert.equal(new Headers(seen.init.headers).get('content-type'),
                     'application/sexpr');
        assert.ok(same(v, [sym('ok'), 1n]));
    });
});

test('rpc keeps 42 exact and reads a reply as UTF-8 whatever the header says', async () => {
    await withFetch(async (url, init) => {
        assert.equal(init.body, '(get-user 42)');
        // a server that mislabels the charset must not change what the
        // bytes mean: Response.text() is UTF-8 regardless
        return sexprResponse('(ok "中文")',
                             { headers: { 'Content-Type': 'text/plain; charset=latin1' } });
    }, async () => {
        const v = await rpc('/api', 'get-user', 42);
        assert.ok(same(v, [sym('ok'), '中文']));
    });
});

test('a reply that is not valid UTF-8 is refused, not repaired', async () => {
    // Response.text() replaces a malformed byte with U+FFFD, so this
    // reply would have arrived as the string "\uFFFD" -- a value the
    // peer never sent
    await withFetch(async () => new Response(Uint8Array.from([0x22, 0xff, 0x22])),
        async () => {
            await assert.rejects(() => rpc('/api', 'ping'), /not valid UTF-8/);
        });
    // well-formed multi-byte text still arrives intact
    await withFetch(async () => sexprResponse('(ok "中文\u{1F600}")'), async () => {
        assert.ok(same(await rpc('/api', 'ping'), [sym('ok'), '中文\u{1F600}']));
    });
});

test('an (error ...) reply is data, not a rejection', async () => {
    await withFetch(async () => sexprResponse('(error "no such user")'), async () => {
        assert.ok(same(await rpc('/api', 'get-user', 1),
                       [sym('error'), 'no such user']));
    });
    await withFetch(async () => sexprResponse('(error "no such user")'), async () => {
        assert.deepStrictEqual(await rpcJSON('/api', 'get-user', 1),
                               ['error', 'no such user']);
    });
});

test('the transport failing is a rejection, and the body is not read', async () => {
    let bodyRead = false;
    await withFetch(async () => ({
        ok: false, status: 503,
        text: async () => { bodyRead = true; return 'ignored'; },
    }), async () => {
        await assert.rejects(() => rpc('/api', 'ping'), e => e.status === 503);
        assert.equal(bodyRead, false, 'a failed response should not be parsed');
    });
    await withFetch(async () => { throw new TypeError('network down'); }, async () => {
        await assert.rejects(() => rpc('/api', 'ping'), /network down/);
    });
});

test('a bad 2xx reply rejects with the position the authority would give', async () => {
    await withFetch(async () => sexprResponse('(1 2'), async () => {
        await assert.rejects(() => rpc('/api', 'ping'), e => {
            assert.ok(e instanceof SexprError);
            assert.equal(e.position, 4);
            return true;
        });
    });
});

test('an object or array argument reaches the wire', async () => {
    // fromJSON USED TO take a second parameter (the cycle set), so
    // passing it straight to Array.map handed it the index and every
    // structured argument died before fetch.  It now takes exactly one
    // and refuses a second -- see "fromJSON takes one argument" -- but
    // this case is what noticed, so it stays.  One call with each shape.
    let body = null;
    await withFetch(async (url, init) => { body = init.body; return sexprResponse('(ok)'); },
        async () => {
            await rpc('/api', 'put', { a: 1 }, [2, 3], 'x');
            assert.equal(body, '(put ((a . 1)) (2 3) "x")');
        });
});

test('a request that cannot be written is never sent', async () => {
    let called = false;
    await withFetch(async () => { called = true; return sexprResponse('()'); },
        async () => {
            await assert.rejects(() => rpc('/api', 'ping', sym('12')), SexprError);
            assert.equal(called, false, 'an unwritable argument still hit the network');
        });
});

// ---- F. the fixture, and the module's independence ------------------

test('rt/sexpr.mjs depends on nothing but the language', () => {
    // a static read, not a doctored global: `process` cannot be deleted
    // convincingly, and a fake isolation that passes proves nothing
    const raw = fs.readFileSync(path.join(HERE, '../rt/sexpr.mjs'), 'utf8');
    // strip comments first: the header says "no Buffer" in prose, and a
    // scanner that reads prose would report the promise as the breach
    const src = raw.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
    for (const forbidden of [/\brequire\s*\(/, /from\s+['"]node:/, /\bBuffer\b/,
                             /\bprocess\b/, /\b__dirname\b/, /\bglobal\b(?!This)/])
        assert.ok(!forbidden.test(src),
            `rt/sexpr.mjs mentions ${forbidden}; it must run unchanged in a browser`);
    assert.match(src, /export /, 'it is an ES module');
});

test('the fixture is whole, named and self-consistent', () => {
    assert.equal(FIXTURE.authority, '(igropyr sexpr)');
    assert.match(FIXTURE.entry_points, /string->sexpr-extended/);
    assert.ok(FIXTURE.authority_commit && FIXTURE.authority_commit !== 'unknown',
        'the fixture does not record which igropyr generated it');
    // ONE id names only the file it came from.  base64 lives in
    // crypto.sc and decides half the read verdicts, so its commit is
    // required too -- otherwise a clean commit touching only that file
    // changes the golden while the provenance stays put.
    assert.ok(FIXTURE.authority_commits, 'the fixture records no per-file commits');
    for (const f of ['sexpr.sc', 'crypto.sc'])
        assert.match(FIXTURE.authority_commits[f] || '', /^[0-9a-f]{40}$/,
            `no commit recorded for ${f}`);
    assert.equal(FIXTURE.authority_commits['sexpr.sc'], FIXTURE.authority_commit,
        'the singleton id disagrees with the per-file map');
    assert.deepStrictEqual(Object.keys(FIXTURE.authority_commits).sort(),
                           ['crypto.sc', 'sexpr.sc'],
                           'the provenance map names other than the measured sources');
    // The second id is not the first one copied under another key --
    // filling both from the singleton would satisfy every assertion
    // above.  What this does NOT establish is that the id is crypto.sc's
    // own last-touch commit: any other distinct 40-hex value (the
    // checkout's HEAD, say) would pass here.  That property is enforced
    // where it can be, at generation time: the generator compares each
    // file's bytes against `git show <that commit>:<file>`, so an id
    // naming a different version cannot survive.  (If upstream ever
    // lands one commit touching both files these become legitimately
    // equal, and updating this line is then a deliberate edit.)
    assert.notEqual(FIXTURE.authority_commits['crypto.sc'],
                    FIXTURE.authority_commit,
                    'crypto.sc carries sexpr.sc\'s commit; the map is a copy');
    for (const group of ['write', 'read', 'write_reject']) {
        const names = FIXTURE[group].map(e => e.name);
        assert.equal(new Set(names).size, names.length,
            `duplicate names in ${group}`);
        // The generator wrote down how many it produced, so a fixture
        // EDITED BY HAND disagrees with its own record.  Note what this
        // does not catch: deleting a case from the generator and
        // regenerating updates both sides at once.  That is a visible
        // change to a tracked file rather than a silent one, which is
        // the line this check draws -- it defends the fixture's
        // integrity, not the generator's coverage.  Coverage is what
        // the named-membership assertions below are for.
        assert.equal(FIXTURE[group].length, FIXTURE.counts[group],
            `${group} has ${FIXTURE[group].length} entries, but the generator `
            + `recorded ${FIXTURE.counts[group]} -- entries were removed`);
    }
    // the base64 wrapper is canonical: decode then re-encode must agree
    for (const e of FIXTURE.write) {
        if (!e.wire_b64) continue;
        const bytes = Uint8Array.from(Buffer.from(e.wire_b64, 'base64'));
        assert.equal(base64Encode(bytes), e.wire_b64,
            `${e.name}: non-canonical base64 in the fixture`);
    }
    // the vector set is named, not counted: a fixture that lost every
    // flonum case would still satisfy a total
    const have = new Set(FIXTURE.write.map(e => e.name));
    for (const required of ['int-zero', 'int-neg-2^90', 'ratio-neg-seven-halves',
                            'string-unicode', 'string-literal-newline',
                            'symbol-punctuation', 'empty-list', 'list-dotted',
                            'list-alist', 'vector-empty', 'bytevector-0-1-255',
                            'flonum-neg-zero', 'flonum-nan', 'flonum-nan-negative',
                            'deep-63', 'deep-64-atom'])
        assert.ok(have.has(required), `the fixture lost the "${required}" vector`);
    // named membership on the read and symbol groups too: thresholds
    // alone let an ordinary entry be deleted without a sound
    // THE SAME LIST the Scheme read suite names, spelled identically.
    // Two lists that overlapped but differed meant the same deletion was
    // caught by one suite and not the other -- and every asymmetry
    // between these suites has been a hole in whichever asserted less.
    for (const required of [
                             'read-int', 'read-ratio-reduces',
                             'read-plus-five', 'read-trailing-datum',
                             'read-deep-63-empty', 'read-deep-65-empty',
                             'read-deep-64-atom', 'read-deep-65-atom',
                             'read-token-65536', 'read-token-65537',
                             'read-number-token-65536',
                             'read-number-token-65537',
                             'read-bv-bad-padding',
                             'read-bv-noncanonical-tail',
                             'read-bv-all-padding',
                             'read-bv-padding-midway',
                             'read-f8-wrong-length', 'read-f8-noncanonical',
                             'read-astral-then-error',
                             'read-astral-trailing', 'read-ratio-zero-den',
                             'read-double-slash'])
        assert.ok(FIXTURE.read.some(e => e.name === required),
            `the fixture lost the "${required}" probe`);
    // The depth boundary moves with WHAT SITS INNERMOST: at the same
    // parenthesis count, a nest ending in `()` is accepted where one
    // ending in an atom is refused, because the empty list is
    // recognised while an atom costs one more descent. Two probes with
    // identical paren counts and opposite verdicts are the whole point
    // of the pair, so the pair is asserted rather than left to the
    // generic sweep.
    const probe = (n) => FIXTURE.read.find(e => e.name === n);
    const opens = (e) => Array.from(readInput(e)).filter(c => c === '(').length;
    // depth AND what sits innermost, both asserted -- relying on the
    // name to tell you which is which is relying on the thing the pair
    // exists to check
    const innermost = (n) => {
        const t = readInput(probe(n));
        const open = t.lastIndexOf('(');
        return t.slice(open, t.indexOf(')', open) + 1);
    };
    for (const [n, parens, inner, ok] of [
        ['read-deep-63-empty', 63, '()', true],
        ['read-deep-65-empty', 65, '()', true],
        ['read-deep-64-atom', 64, '(1)', true],
        ['read-deep-65-atom', 65, '(1)', false],
    ]) {
        assert.equal(opens(probe(n)), parens, `${n}: paren count`);
        assert.equal(innermost(n), inner, `${n}: innermost datum`);
        assert.equal(probe(n).accepted, ok, `${n}: verdict`);
    }
    // the symbol matrix must still carry each family, by content
    const names = new Set(FIXTURE.write_reject.map(e => e.sym));
    for (const required of ['ok', '12', '+1', '0x10', '1/-2', '+i', '-i',
                            '+1@2', '+inf.0i', '1/0', '.', '',
                            // the casings and the cross-family forms:
                            // without these the corpus can lose the
                            // dimension that makes the predicate fixes
                            // evidence rather than assertion
                            '+I', '+1I', '+INF.0I', '1+2I',
                            '+1e3+2i', '+1/2+3/4i', '+1/2@3/4', '+1e3@2s3',
                            '1S3', 'NaN.0', 'iNf.0',
                            // the polar right operand's sign: without
                            // these the generator can stop producing
                            // them and the predicate fix loses its
                            // evidence while every count still agrees
                            '+1@-2', '+1@+2', '+1/2@-3/4', '+1@+inf.0'])
        assert.ok(names.has(required),
            `the symbol matrix lost ${JSON.stringify(required)}`);
    // both read verdicts, and the middle case
    assert.ok(FIXTURE.read.some(e => e.accepted && e.rewritable));
    assert.ok(FIXTURE.read.some(e => e.accepted && e.rewritable === false));
    assert.ok(FIXTURE.read.some(e => !e.accepted));
    // the extended types are all exercised, so a strict-mode dispatch
    // could not pass this file
    const inputs = FIXTURE.read.map(e => readInput(e)).join('\n');
    for (const form of ['#f8"', '#vu8"', '#('])
        assert.ok(inputs.includes(form), `no probe carries ${form}`);
});

test('the fixture decoder is fatal, not repairing', () => {
    // the fixture is valid today, so reverting the decoder to
    // replacement mode would go unnoticed without a synthetic case
    assert.throws(() => dec.decode(Uint8Array.from([0x22, 0xff, 0x22])), TypeError);
    assert.equal(dec.decode(enc.encode('中文')), '中文');
});

test('the CJK and emoji vectors are compared as UTF-8 bytes', () => {
    const e = FIXTURE.write.find(x => x.name === 'string-unicode');
    const bytes = Uint8Array.from(Buffer.from(e.wire_b64, 'base64'));
    // the emoji is four bytes in UTF-8 and two units in UTF-16; this
    // asserts the fixture carries the former
    assert.ok(bytes.length > dec.decode(bytes).length,
        'the fixture entry is not UTF-8 bytes');
    assert.deepStrictEqual(Array.from(enc.encode(write('中文\u{1F600}'))),
                           Array.from(bytes));
});

// ---- H. the anchors: what the wire MEANS ---------------------------
//
// Everything above that round-trips is a FIXED POINT, and a fixed point
// is blind to a matching pair of mistakes: decode a flonum big-endian
// AND encode it big-endian and every byte still agrees while every
// value in between is wrong.  The anchors close that -- the value never
// comes from this codec.  Each fixture anchor carries a spec, the
// reader below builds the value from it, and both directions are
// asserted against the authority's bytes.
//
// The anchor set used to be a list that grew by one entry each time a
// reviewer named a surviving mutation, which made "what is still
// uncovered" a question about someone's imagination.  It is now a cross
// product of type x spelling branch, and the branch names are pinned
// here, so a branch that stops being generated fails by name.

// A prefix token program; every payload is a decimal integer and text
// is carried as UTF-8 bytes, so reading a spec involves no string
// escaping -- the very layer under test.  Grammar: see
// test/gen-sexpr-vectors.sc.  Deliberately not shared with rt/sexpr.mjs:
// a shared reader would move both sides of the comparison at once.
function specRead(toks, at) {
    if (at >= toks.length) throw new Error('spec ends where a datum was due');
    const tag = toks[at++];
    // DIGITS, and at least one.  Folding every character as a digit made
    // `N Z` denote 42 ('Z' - '0'), so a spec could name a value with a
    // token that is not a number -- and each of the three readers of
    // this language answered differently, which is worse than any one
    // of them being wrong.
    const int = (t) => {
        const neg = t[0] === '-';
        const start = neg ? 1 : 0;
        if (t.length <= start) throw new Error(`not a numeral: ${t}`);
        let acc = 0n;
        for (let i = start; i < t.length; i++) {
            const d = t.charCodeAt(i) - 48;
            if (d < 0 || d > 9) throw new Error(`not a numeral: ${t}`);
            acc = acc * 10n + BigInt(d);
        }
        return neg ? -acc : acc;
    };
    const count = (t) => {
        const n = Number(int(t));
        if (n < 0) throw new Error(`negative count: ${t}`);
        return n;
    };
    const bytes = (n) => {
        const out = new Uint8Array(n);
        for (let i = 0; i < n; i++) {
            if (at >= toks.length) throw new Error('spec ends inside a payload');
            const b = Number(int(toks[at++]));
            if (b < 0 || b > 255) throw new Error(`not a byte: ${b}`);
            out[i] = b;
        }
        return out;
    };
    const values = (n) => {
        const out = [];
        for (let i = 0; i < n; i++) {
            if (at >= toks.length) throw new Error('spec ends inside a list');
            const r = specRead(toks, at); out.push(r[0]); at = r[1];
        }
        return out;
    };
    switch (tag) {
    case 'T': return [true, at];
    case 'F': return [false, at];
    case 'NIL': return [[], at];
    case 'N': return [int(toks[at++]), at];
    case 'Q': {
        const n = int(toks[at++]), d = int(toks[at++]);
        if (d === 0n) throw new Error('zero denominator in spec');
        // Q must denote a RATIO: `Q 4 2` is 2 and `Q 0 7` is 0, which N
        // already spells -- the same aliasing as P, one tag over. A tag
        // that can produce a datum outside the kind it names has
        // stopped naming that kind. (Needing reduction, as `Q 2 4`
        // does, is still a ratio; `ratio()` collapses whole numbers, so
        // the test is on what it returns.)
        const q = ratio(n, d);
        if (typeof q === 'bigint')
            throw new Error('ratio that is a whole number');
        return [q, at];
    }
    case 'D': {
        const b = bytes(8);
        const dv = new DataView(new ArrayBuffer(8));
        b.forEach((v, i) => dv.setUint8(i, v));
        return [dv.getFloat64(0, true), at];
    }
    case 'S': return [dec.decode(bytes(count(toks[at++]))), at];
    case 'Y': return [sym(dec.decode(bytes(count(toks[at++])))), at];
    case 'B': return [bytes(count(toks[at++])), at];
    case 'L': return [values(count(toks[at++])), at];
    case 'P': {
        const n = count(toks[at++]);
        // `P 0 X` denotes X: a second spelling of an anchor that exists
        if (n < 1) throw new Error('improper list with no elements in spec');
        const items = values(n);
        const r = specRead(toks, at);
        // the tail must be an ATOM: neither () nor a pair. A tail that
        // is a list merges into the enclosing one, so `P 1 N 1 NIL` is
        // `(1)`, `P 1 N 1 L 1 N 2` is `(1 2)` and `P 1 N 1 P 1 N 2 N 3`
        // is `(1 2 . 3)` -- each a second spelling of a datum that
        // already has one. Refusing only () fixed one level, and a
        // nested P walked straight through it.
        if (Array.isArray(r[0]) || r[0] instanceof DottedList)
            throw new Error('improper list whose tail is itself a list');
        return [dotted(items, r[0]), r[1]];
    }
    case 'V': return [new Vec(values(count(toks[at++]))), at];
    default: throw new Error(`unknown spec tag ${tag}`);
    }
}

function specValue(s) {
    const toks = s.split(' ').filter(t => t.length > 0);
    const [v, at] = specRead(toks, 0);
    assert.equal(at, toks.length, `trailing tokens in spec: ${s}`);
    return v;
}

test('the spec reader reads specs', () => {
    // The reader is itself evidence, so it gets its own check against
    // values stated here rather than taken from the fixture.  A reader
    // that mis-counted a length would otherwise make every anchor agree
    // with a wrong value.
    assert.ok(same(specValue('L 2 N 1 S 1 65'), [1n, 'A']));
    assert.ok(same(specValue('P 1 N 1 N 2'), dotted([1n], 2n)));
    assert.ok(same(specValue('V 2 T NIL'), new Vec([true, []])));
    assert.ok(same(specValue('N -42'), -42n));
    assert.ok(same(specValue('D 0 0 0 0 0 0 248 63'), 1.5));
    assert.ok(same(specValue('B 2 1 2'), Uint8Array.from([1, 2])));
    // THE SHARED CORPUS, read from the fixture rather than copied.  It
    // used to be three hand-kept lists in three languages, and a round
    // shipped with two extended and the third left behind while the
    // report said "one shared list, all three".  Copies cannot be kept
    // in step by discipline: the generator emits the list it ran
    // against its own reader, and this runs the same programs.
    //
    // The wellformed half is not decoration -- a reader that refused
    // everything would satisfy the malformed half perfectly.
    const MALFORMED = FIXTURE.spec_malformed || [];
    const WELLFORMED = FIXTURE.spec_wellformed || [];
    // sizes pinned, and the programs that were real defects named: a
    // truncated corpus would pass every line of the loops below
    assert.equal(MALFORMED.length, 32);
    assert.equal(WELLFORMED.length, 23);
    // every member of an aliasing family, not just the first: the P
    // rule was fixed one level too shallow twice, and a corpus naming
    // only `P 1 N 1 NIL` lets the other two be swapped for a duplicate
    // while the size still matches
    for (const must of ['N Z', 'L 1 Z', 'S 1 255', 'P 0 N 1', 'L -1',
                        'P 1 N 1 NIL', 'P 1 N 1 L 1 N 2',
                        'P 1 N 1 P 1 N 2 N 3'])
        assert.ok(MALFORMED.includes(must), `corpus no longer names ${must}`);
    // ...and no entry appears twice, which is what let a substitution
    // keep the size while dropping a program
    assert.equal(new Set(MALFORMED).size, MALFORMED.length,
        'a malformed program appears twice');
    assert.equal(new Set(WELLFORMED.map(e => e.spec)).size, WELLFORMED.length,
        'a well-formed program appears twice');
    for (const bad of MALFORMED)
        assert.throws(() => specValue(bad), undefined, `accepted: ${bad}`);
    // ACCEPTED is not READ RIGHT: these were checked only for "does not
    // throw", so a reader taking a ratio as n/|d| made `Q 1 -2` denote
    // +1/2 and stayed on the list. Each program carries the authority's
    // bytes for the value it denotes.
    for (const e of WELLFORMED) {
        const wire = dec.decode(Uint8Array.from(Buffer.from(e.wire_b64, 'base64')));
        assert.equal(write(specValue(e.spec)), wire,
            `${e.spec} does not denote what the authority wrote`);
    }
    // EVERY pair, not a chosen eight. Two rounds of narrowing here:
    // first the corpus was pinned only by size (so a program could be
    // swapped for an equivalent one), then only by `why` (so a program
    // could be swapped while its claim stayed), and pinning eight of
    // twenty-three left fifteen entries whose stated reason could be
    // replaced by a false one with nothing red. The corpus is small and
    // the claims are the point, so all of it is stated here -- the same
    // treatment the branch matrix gets, and for the same reason: a new
    // claimed reader path should be a decision in both consumers, not a
    // number that drifts.
    for (const [spec, why] of [
        ["N 42",
         "a plain numeral"],
        ["N -42",
         "a negative numeral"],
        ["N 0",
         "zero"],
        ["T",
         "true"],
        ["F",
         "false -- and the value #f is not the failure #f"],
        ["NIL",
         "the empty list"],
        ["Q 355 113",
         "a ratio already in lowest terms"],
        ["Q 1 -2",
         "the sign arriving on the DENOMINATOR"],
        ["Q -1 2",
         "the sign arriving on the NUMERATOR"],
        ["Q 2 4",
         "a ratio that needs reducing"],
        ["L 2 N 1 S 1 65",
         "a list of mixed kinds"],
        ["L 0",
         "the counted-list path at length zero"],
        ["P 1 N 1 N 2",
         "an improper list"],
        ["V 2 T NIL",
         "a vector of mixed kinds"],
        ["V 0",
         "the empty vector, which is not the empty list"],
        ["B 2 1 2",
         "a bytevector"],
        ["B 0",
         "the empty bytevector"],
        ["D 0 0 0 0 0 0 248 63",
         "a flonum from its bits"],
        ["D 0 0 0 0 0 0 0 128",
         "a NEGATIVE ZERO, whose sign no decimal carries"],
        ["S 0",
         "the empty string"],
        ["Y 2 111 107",
         "a symbol"],
        ["S 4 240 159 152 128",
         "a four-byte UTF-8 sequence"],
        ["S 3 97 10 98",
         "a control character inside a string"],
    ])
        assert.ok(WELLFORMED.some(e => e.spec === spec && e.why === why),
            `no entry pairs ${spec} with "${why}"`);
    // BigInt, not Number: the whole point of the N tag is exactness
    assert.equal(typeof specValue('N 1'), 'bigint');
});

// The type column asserted against the value THE CODEC returned.  Most
// of what this rules out `same` already rules out; what it adds is that
// the fixture's type column has to be true -- otherwise it is a comment
// that happens to sit in a data file, and a wrong one would never show.
const TYPE_TESTS = {
    boolean: v => typeof v === 'boolean',
    null: v => Array.isArray(v) && v.length === 0,
    integer: v => typeof v === 'bigint',
    ratio: v => v instanceof Ratio,
    flonum: v => typeof v === 'number',
    string: v => typeof v === 'string',
    symbol: v => v instanceof Sym,
    bytevector: v => v instanceof Uint8Array,
    vector: v => v instanceof Vec,
    list: v => Array.isArray(v) ? v.length > 0 : v instanceof DottedList,
    // an atom placed inside a compound: the compound is what comes back,
    // and `same` is what checks the atom is still there in its place
    nesting: v => Array.isArray(v) || v instanceof Vec || v instanceof DottedList,
};

// THE SAME FUNCTION the generator used to name the cell, recomputed
// here on the decoded value and compared by equality.
//
// This replaced a table of predicates, because a predicate table means
// nothing unless its clauses are mutually exclusive and ours were not:
// -0 satisfied both `negative-zero` and a generic `flonum`, a string
// with a control character AND a multi-byte sequence satisfied two, and
// nothing asserted exclusivity. A total function into one label cannot
// have that problem.
const FIXNUM_MAX = 536870911n;
const FIXNUM_MIN = -536870912n;   // i31 with a tag bit: NOT symmetric

function stringLabel(str) {
    const bytes = new TextEncoder().encode(str);
    const control = bytes.some(b => b < 32);
    const escape = bytes.some(b => b === 34 || b === 92);
    const high = bytes.some(b => b >= 128);
    const n = (control ? 1 : 0) + (escape ? 1 : 0) + (high ? 1 : 0);
    if (n === 0) return 'plain-string';
    if (n > 1) return 'ambiguous-string';
    return control ? 'control-string' : escape ? 'escape-string' : 'utf8-string';
}

function nestingLabel(v) {
    if (v === false) return 'false';
    if (v === true) return 'true';
    if (typeof v === 'number')
        return Object.is(v, -0) ? 'negative-zero' : 'flonum';
    if (typeof v === 'bigint')
        // asymmetric on purpose: -536870912 IS a fixnum, and testing the
        // absolute value called it a bignum, so every bignum-* cell
        // could have held a fixnum and stayed green
        return (v > FIXNUM_MAX || v < FIXNUM_MIN) ? 'bignum' : 'small-integer';
    if (v instanceof Ratio) return 'ratio';
    if (v instanceof Uint8Array)
        return `bytevector-pad${(3 - v.length % 3) % 3}`;
    if (Array.isArray(v)) return v.length === 0 ? 'empty-list' : 'proper-list';
    if (v instanceof Vec) return 'vector';
    // the tail loop's null arm and its dotted arm are two branches, so a
    // proper list and a dotted pair are two atoms, not one
    if (v instanceof DottedList) return 'dotted-pair';
    if (typeof v === 'string') return stringLabel(v);
    if (v instanceof Sym)
        return /[*+\-<=>?!]/.test(v.name) ? 'punctuation-symbol' : 'plain-symbol';
    return 'no-label';
}

const NO_SUCH = Symbol('no such position');
function atomAt(position, v) {
    const items = v instanceof Vec ? v.items
        : v instanceof DottedList ? v.items : Array.isArray(v) ? v : null;
    // the CONTAINER KIND is part of the position. Treating in-list and
    // in-vector as one case let their metadata be swapped with nothing
    // red, while the Scheme suite -- which checks the kind -- rejected
    // it: every asymmetry between these two suites so far has been a
    // real hole in whichever one asserted less.
    const isList = Array.isArray(v) || v instanceof DottedList;
    switch (position) {
    case 'head-of-list':
        return isList && items.length > 0 ? items[0] : NO_SUCH;
    case 'in-list':
        return isList && items.length > 1 ? items[1] : NO_SUCH;
    case 'in-vector':
        return v instanceof Vec && items.length > 1 ? items[1] : NO_SUCH;
    case 'deep': {
        // an inner improper list counts too, as it does in Scheme where
        // the extractor only asks for a pair
        const inner = isList && items.length > 1 ? items[1] : NO_SUCH;
        const innerItems = Array.isArray(inner) ? inner
            : inner instanceof DottedList ? inner.items : null;
        return innerItems && innerItems.length > 1 ? innerItems[1] : NO_SUCH;
    }
    case 'as-tail':
        // the CDR, which is what the Scheme extractor takes -- not the
        // final tail. They agree on a one-element improper list and
        // diverge as soon as the spine is longer, and the two suites
        // disagreeing about what a position MEANS is the same class of
        // hole as one of them not checking it at all.
        if (!(v instanceof DottedList)) return NO_SUCH;
        return v.items.length === 1 ? v.tail
            : dotted(v.items.slice(1), v.tail);
    default: return NO_SUCH;
    }
}

const ANCHORS = FIXTURE.anchors || [];
const HOLES = FIXTURE.nesting_holes || [];
const anchorWire = e =>
    dec.decode(Uint8Array.from(Buffer.from(e.wire_b64, 'base64')));

test('every anchor decodes and re-encodes to the authority bytes', () => {
    assert.ok(ANCHORS.length > 0, 'the fixture carries no anchors');
    for (const a of ANCHORS) {
        const where = `${a.type}/${a.branch}`;
        const wire = anchorWire(a);
        const want = specValue(a.spec);
        const got = read(wire);
        assert.ok(TYPE_TESTS[a.type], `no type test for ${a.type}`);
        assert.ok(TYPE_TESTS[a.type](got), `${where}: decoded value is not a ${a.type}`);
        assert.ok(same(got, want), `${where}: decoded value is not the anchored value`);
        // direction=read marks a spelling the authority accepts but does
        // not itself emit (the escaped form of a control character);
        // asserting the writer against those bytes would be asserting
        // the wrong thing, and the generator measured which is which
        // A nesting cell's branch NAME is not a check: replacing the
        // bytevector atom with the integer 255 upstream left every
        // "bytevector-*" branch holding an integer and nothing red.  The
        // atom's type and its position are data, asserted here.
        // EVERY anchor names what its value is. A top-level branch used
        // to be checked against nothing finer than its type, so swapping
        // the values and wires of `boolean/true` and `boolean/false`
        // left both names false with everything green. (What this does
        // not discriminate is a pair sharing a label: `integer/positive`
        // and `integer/negative` are both `small-integer`, so those
        // names stay conventions rather than checked claims.)
        // ...for a TOP-LEVEL anchor. A nesting cell's atom describes the
        // value at its position, not the whole datum, and is checked
        // below.
        if (!a.position)
            assert.equal(nestingLabel(got), a.atom,
                `${where}: filed as ${a.atom} but the value is not one`);
        if (a.position) {
            // the NAME must say what the columns say, or a depth-two
            // cell can be recorded as "in-list" -- whose extractor finds
            // the intermediate list and passes a loose test -- while the
            // branch still advertises "deep"
            assert.ok(a.branch === `${a.atom}-${a.position}`
                      || a.branch === `${a.atom}-${a.position}-escaped`,
                `${where}: the name does not say what the columns say`);
            const found = atomAt(a.position, got);
            assert.ok(found !== NO_SUCH, `${where}: no value ${a.position}`);
            assert.equal(nestingLabel(found), a.atom,
                `${where}: what is ${a.position} is not a ${a.atom}`);
        }
        // The writer runs for EVERY anchor.  `direction` is the
        // generator's measurement of the authority, and a fixture that
        // downgraded a measured "both" to "read" would otherwise buy
        // itself a skipped writer check -- so "read" is asserted as the
        // writer NOT producing that wire.
        const written = write(want);
        if (a.direction === 'both')
            assert.equal(written, wire, `${where}: written differently`);
        else {
            assert.equal(a.direction, 'read', `${where}: unknown direction`);
            assert.notEqual(written, wire,
                `${where}: marked read-only, but our writer emits exactly `
                + 'this wire -- either the fixture downgraded a measured '
                + 'direction or the writer disagrees with the authority');
        }
    }
});

// (branch, atom) PAIRS, not names. The atom column was checked against
// the decoded value but never against the branch carrying it, so
// swapping the complete contents of `boolean/true` and `boolean/false`
// -- atom included -- left both names false with everything green.
// Pinning the pair is the same move the well-formed corpus needed: a
// claim has to be attached to something.
//
// It does not make every branch name a checked claim. `flonum/half` and
// `flonum/repeating` are both `flonum`; `integer/positive` and
// `integer/negative` are both `small-integer`. Where two branches share
// a label, their names stay conventions.
const EXPECTED_PAIRS = [
    ["boolean/true", "true"],
    ["boolean/false", "false"],
    ["null/empty-list", "empty-list"],
    ["integer/zero", "small-integer"],
    ["integer/positive", "small-integer"],
    ["integer/negative", "small-integer"],
    ["integer/bignum-positive", "bignum"],
    ["integer/bignum-negative", "bignum"],
    ["integer/fixnum-edge-positive", "small-integer"],
    ["integer/fixnum-edge-negative", "small-integer"],
    ["integer/fixnum-edge-past", "bignum"],
    ["ratio/positive", "ratio"],
    ["ratio/negative", "ratio"],
    ["flonum/half", "flonum"],
    ["flonum/integral", "flonum"],
    ["flonum/repeating", "flonum"],
    ["flonum/negative", "flonum"],
    ["flonum/positive-zero", "flonum"],
    ["flonum/negative-zero", "negative-zero"],
    ["flonum/positive-infinity", "flonum"],
    ["flonum/negative-infinity", "flonum"],
    ["flonum/nan-quiet", "flonum"],
    ["flonum/nan-payload", "flonum"],
    ["flonum/nan-negative", "flonum"],
    ["flonum/min-subnormal", "flonum"],
    ["flonum/min-normal", "flonum"],
    ["flonum/max-finite", "flonum"],
    ["string/empty", "plain-string"],
    ["string/ascii", "plain-string"],
    ["string/quote", "escape-string"],
    ["string/backslash", "escape-string"],
    ["string/latin1", "utf8-string"],
    ["string/cjk", "utf8-string"],
    ["string/astral", "utf8-string"],
    ["symbol/plain", "plain-symbol"],
    ["symbol/hyphenated", "punctuation-symbol"],
    ["symbol/punctuation", "punctuation-symbol"],
    ["symbol/case-lower", "plain-symbol"],
    ["symbol/case-upper", "plain-symbol"],
    ["symbol/case-mixed", "plain-symbol"],
    ["bytevector/empty", "bytevector-pad0"],
    ["bytevector/one-byte", "bytevector-pad2"],
    ["bytevector/two-bytes", "bytevector-pad1"],
    ["bytevector/three-bytes", "bytevector-pad0"],
    ["bytevector/zero-byte", "bytevector-pad2"],
    ["bytevector/whole-alphabet", "bytevector-pad0"],
    ["vector/empty", "vector"],
    ["vector/single", "vector"],
    ["vector/nested", "vector"],
    ["vector/mixed", "vector"],
    ["list/single", "proper-list"],
    ["list/proper", "proper-list"],
    ["list/dotted-pair", "dotted-pair"],
    ["list/dotted-tail", "dotted-pair"],
    ["list/nested", "proper-list"],
    ["list/alist", "proper-list"],
    ["list/mixed", "proper-list"],
    ["list/containing-empty", "proper-list"],
    ["nesting/negative-zero-head-of-list", "negative-zero"],
    ["nesting/negative-zero-in-list", "negative-zero"],
    ["nesting/negative-zero-in-vector", "negative-zero"],
    ["nesting/negative-zero-as-tail", "negative-zero"],
    ["nesting/negative-zero-deep", "negative-zero"],
    ["nesting/ratio-head-of-list", "ratio"],
    ["nesting/ratio-in-list", "ratio"],
    ["nesting/ratio-in-vector", "ratio"],
    ["nesting/ratio-as-tail", "ratio"],
    ["nesting/ratio-deep", "ratio"],
    ["nesting/bignum-head-of-list", "bignum"],
    ["nesting/bignum-in-list", "bignum"],
    ["nesting/bignum-in-vector", "bignum"],
    ["nesting/bignum-as-tail", "bignum"],
    ["nesting/bignum-deep", "bignum"],
    ["nesting/bytevector-pad2-head-of-list", "bytevector-pad2"],
    ["nesting/bytevector-pad2-in-list", "bytevector-pad2"],
    ["nesting/bytevector-pad2-in-vector", "bytevector-pad2"],
    ["nesting/bytevector-pad2-as-tail", "bytevector-pad2"],
    ["nesting/bytevector-pad2-deep", "bytevector-pad2"],
    ["nesting/bytevector-pad1-head-of-list", "bytevector-pad1"],
    ["nesting/bytevector-pad1-in-list", "bytevector-pad1"],
    ["nesting/bytevector-pad1-in-vector", "bytevector-pad1"],
    ["nesting/bytevector-pad1-as-tail", "bytevector-pad1"],
    ["nesting/bytevector-pad1-deep", "bytevector-pad1"],
    ["nesting/bytevector-pad0-head-of-list", "bytevector-pad0"],
    ["nesting/bytevector-pad0-in-list", "bytevector-pad0"],
    ["nesting/bytevector-pad0-in-vector", "bytevector-pad0"],
    ["nesting/bytevector-pad0-as-tail", "bytevector-pad0"],
    ["nesting/bytevector-pad0-deep", "bytevector-pad0"],
    ["nesting/control-string-head-of-list", "control-string"],
    ["nesting/control-string-in-list", "control-string"],
    ["nesting/control-string-in-vector", "control-string"],
    ["nesting/control-string-as-tail", "control-string"],
    ["nesting/control-string-deep", "control-string"],
    ["nesting/escape-string-head-of-list", "escape-string"],
    ["nesting/escape-string-in-list", "escape-string"],
    ["nesting/escape-string-in-vector", "escape-string"],
    ["nesting/escape-string-as-tail", "escape-string"],
    ["nesting/escape-string-deep", "escape-string"],
    ["nesting/utf8-string-head-of-list", "utf8-string"],
    ["nesting/utf8-string-in-list", "utf8-string"],
    ["nesting/utf8-string-in-vector", "utf8-string"],
    ["nesting/utf8-string-as-tail", "utf8-string"],
    ["nesting/utf8-string-deep", "utf8-string"],
    ["nesting/punctuation-symbol-head-of-list", "punctuation-symbol"],
    ["nesting/punctuation-symbol-in-list", "punctuation-symbol"],
    ["nesting/punctuation-symbol-in-vector", "punctuation-symbol"],
    ["nesting/punctuation-symbol-as-tail", "punctuation-symbol"],
    ["nesting/punctuation-symbol-deep", "punctuation-symbol"],
    ["nesting/false-head-of-list", "false"],
    ["nesting/false-in-list", "false"],
    ["nesting/false-in-vector", "false"],
    ["nesting/false-as-tail", "false"],
    ["nesting/false-deep", "false"],
    ["nesting/true-head-of-list", "true"],
    ["nesting/true-in-list", "true"],
    ["nesting/true-in-vector", "true"],
    ["nesting/true-as-tail", "true"],
    ["nesting/true-deep", "true"],
    ["nesting/empty-list-head-of-list", "empty-list"],
    ["nesting/empty-list-in-list", "empty-list"],
    ["nesting/empty-list-in-vector", "empty-list"],
    ["nesting/empty-list-deep", "empty-list"],
    ["nesting/vector-head-of-list", "vector"],
    ["nesting/vector-in-list", "vector"],
    ["nesting/vector-in-vector", "vector"],
    ["nesting/vector-as-tail", "vector"],
    ["nesting/vector-deep", "vector"],
    ["nesting/proper-list-head-of-list", "proper-list"],
    ["nesting/proper-list-in-list", "proper-list"],
    ["nesting/proper-list-in-vector", "proper-list"],
    ["nesting/proper-list-deep", "proper-list"],
    ["nesting/dotted-pair-head-of-list", "dotted-pair"],
    ["nesting/dotted-pair-in-list", "dotted-pair"],
    ["nesting/dotted-pair-in-vector", "dotted-pair"],
    ["nesting/dotted-pair-deep", "dotted-pair"],
    ["nesting/control-string-head-of-list-escaped", "control-string"],
    ["nesting/control-string-in-list-escaped", "control-string"],
    ["nesting/control-string-in-vector-escaped", "control-string"],
    ["nesting/control-string-as-tail-escaped", "control-string"],
    ["nesting/control-string-deep-escaped", "control-string"],
    ["string/control-newline-raw", "control-string"],
    ["string/control-newline-escaped", "control-string"],
    ["string/control-tab-raw", "control-string"],
    ["string/control-tab-escaped", "control-string"],
    ["string/control-return-raw", "control-string"],
    ["string/control-return-escaped", "control-string"],
];
const EXPECTED_BRANCHES = EXPECTED_PAIRS.map(p => p[0]);

test('the whole-alphabet bytevector uses the whole alphabet', () => {
    // The branch NAME is a claim about the payload, and pinning only
    // its `bytevector-pad0` label left that claim unchecked here -- the
    // value it names was wrong for a long time (38 distinct characters
    // out of 64) with everything green. The generator refuses to emit a
    // wrong one; this is the consumer end of the same claim.
    const a = ANCHORS.find(x => x.branch === 'whole-alphabet');
    assert.ok(a, 'no whole-alphabet anchor');
    assert.equal(anchorWire(a),
        '#vu8"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"');
});

test('the cross products are full in both dimensions', () => {
    // Every gap this matrix has had was an unfilled cell of a cross
    // product, and every one was found by hand-sweeping the fixture
    // afterwards. The last was introduced BY the edit that fixed the
    // one before it: a fifth position joined the atom product and not
    // the escaped-spelling cells, so direction=read existed at four
    // positions and not the fifth. So the sweep is asserted, not
    // remembered -- and it has to be over PAIRS: a per-dimension count
    // sees every atom and every position present and cannot see that
    // two of them never varied together.
    const positionOf = a => a.position || 'top';
    // ...or a RECORDED hole. Some cells of this product are not data the
    // format has: a tail that is an empty or proper list collapses into
    // the list itself. The generator drops those and writes down which,
    // with the reason, so an absent cell is either a fact about the
    // format or a failure -- never a silence.
    const excused = (a, b) =>
        HOLES.some(h => h.atom === a && h.position === b);
    const full = (name, rows, aOf, bOf) => {
        const as = [...new Set(rows.map(aOf))];
        const bs = [...new Set(rows.map(bOf))];
        for (const a of as)
            for (const b of bs)
                assert.ok(rows.some(r => aOf(r) === a && bOf(r) === b)
                          || excused(a, b),
                    `${name}: no cell for ${a} x ${b}`);
    };
    // nesting cells are the ones with a POSITION: every anchor carries
    // an atom now, so that column no longer distinguishes them
    const nesting = ANCHORS.filter(a => a.position);
    assert.ok(nesting.length > 0, 'no nesting cells at all');
    full('atom x position', nesting, a => a.atom, positionOf);
    full('position x direction', ANCHORS, positionOf, a => a.direction);
    // The holes are pinned like the branches: a new one is a decision
    // about the format, not a number to update. And a hole with no
    // reason is a hole nobody explained.
    assert.equal(HOLES.length, 3);
    for (const [atom, position] of [['empty-list', 'as-tail'],
                                    ['proper-list', 'as-tail'],
                                    ['dotted-pair', 'as-tail']])
        // the reason must SAY THE THING that makes it a hole. "Non-empty"
        // was the whole test, so any plausible-sounding sentence excused
        // a missing cell -- the same gap that pinning only the size of
        // the well-formed corpus left, one section over.
        assert.ok(HOLES.some(h => h.atom === atom && h.position === position
            && (h.reason || '').includes(
                'a tail that is itself a list or a pair merges into the '
                + 'enclosing list')),
            `no explained hole for ${atom} x ${position}`);
});

test('the anchor matrix is exactly the pinned set', () => {
    const seen = ANCHORS.map(a => `${a.type}/${a.branch}`);
    // set equality both ways: "every pinned branch is present" alone
    // would pass a fixture that also carried a branch asserted nowhere
    assert.deepStrictEqual(seen.slice().sort(), EXPECTED_BRANCHES.slice().sort());
    // ...and each branch carries the atom it is pinned with
    for (const [name, atom] of EXPECTED_PAIRS) {
        const hit = ANCHORS.find(a => `${a.type}/${a.branch}` === name);
        if (hit) assert.equal(hit.atom, atom,
            `${name} is pinned as ${atom} but carries ${hit.atom}`);
    }
    // no "a branch appears twice" check: the sorted-array equality above
    // already fixes the multiset, so a duplicate cannot get past it.
    // A product can have degenerate cells -- consing the empty list as a
    // tail gives back a proper list -- and such a cell is an existing
    // anchor under a second name: a row that looks like coverage and is
    // none.  The generator refuses to emit one; a fixture can be edited.
    // The VALUE each spec denotes, not the spec text: `Q 710 226` and
    // `Q 355 113` are one datum spelled two ways, so comparing text
    // lets a semantic duplicate through.
    for (let i = 0; i < ANCHORS.length; i++)
        for (let j = i + 1; j < ANCHORS.length; j++)
            // decoded wires, not the base64 text: two different
            // spellings can decode to the same bytes, and comparing the
            // text let such a duplicate through here while the Scheme
            // side -- which decodes -- rejected it
            assert.ok(!(anchorWire(ANCHORS[i]) === anchorWire(ANCHORS[j])
                        && same(specValue(ANCHORS[i].spec),
                                specValue(ANCHORS[j].spec))),
                `${ANCHORS[i].branch} and ${ANCHORS[j].branch} are the same `
                + 'value written the same way');
    assert.equal(ANCHORS.length, FIXTURE.counts.anchors,
        'the anchor array disagrees with the count the generator wrote');
});

// NOT HERE: a "these pairs must be different wires" check.  It was
// here and never had a mutation of its own: two anchors denoting
// different data cannot share a wire without one of them failing the
// sweep, and two denoting the SAME datum with one wire are a duplicate
// and fail the check above.  What IS kept is the claim below, which
// nothing else makes: the two spellings of a control character denote
// one value.
test('both spellings of a control character mean the same value', () => {
    // ...at every position, not only at top level. The five nested
    // `control-string-<position>-escaped` cells are read-only spellings
    // whose whole point is that they denote the same value as the cell
    // beside them, and only the top-level pairs were tied together: a
    // nested escaped cell could have described a different value and
    // the "the writer does not emit this wire" check would have been
    // satisfied anyway.
    for (const pos of ['head-of-list', 'in-list', 'in-vector',
                       'as-tail', 'deep']) {
        const plain = ANCHORS.find(a => a.branch === `control-string-${pos}`);
        const esc = ANCHORS.find(a =>
            a.branch === `control-string-${pos}-escaped`);
        assert.ok(plain && esc, `missing a spelling at ${pos}`);
        assert.notEqual(anchorWire(plain), anchorWire(esc));
        assert.ok(same(specValue(plain.spec), specValue(esc.spec)),
            `${pos}: the two spellings do not describe the same value`);
    }
    for (const c of ['newline', 'tab', 'return']) {
        const raw = ANCHORS.find(a => a.branch === `control-${c}-raw`);
        const esc = ANCHORS.find(a => a.branch === `control-${c}-escaped`);
        // `raw && esc` is guaranteed by the pinned branch matrix, and
        // "different wires" by the semantic-duplicate check once their
        // specs are equal -- neither can fail here, so neither is
        // asserted.  What is left is the claim nothing else makes.
        assert.ok(same(specValue(raw.spec), specValue(esc.spec)),
            `${c}: the two spellings do not describe the same value`);
    }
});
