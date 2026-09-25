// No shader in this tree converts colour with the gamma 2.2 approximation.
//
// Colours and textures arrive encoded as sRGB, lighting happens in linear
// space, and the result is encoded again for display.  The tree did both
// conversions with pow(x, 2.2) and pow(x, 0.4545) -- eighteen places,
// eleven in lib/gfx and seven in examples/.  That is an approximation of
// the sRGB transfer function, not the function: sRGB is linear near black
// and a 2.4 power above it.  Measured before the switch, the two agree to
// the last 8-bit level on a colour that is decoded and re-encoded
// untouched, and differ by up to six levels once lighting scales it in
// between -- in the dark tones, where the approximation crushes toward
// black.  A rendering library that says sRGB should mean sRGB, so the
// approximation was replaced (ruled 2026-09-25), and this cell keeps it
// from coming back one shader at a time.
//
// WHAT IT READS.  The library's shaders as EMITTED, through
// tools/shader-emit.mjs, because that is what a GPU compiles; a search of
// the Scheme source would also see forms that never reach a shader.  The
// examples are read as source, because each builds its own shaders inline
// and none is registered with the emitter.
//
// WHAT IT DOES NOT SAY.  That the replacement is correct.  A shader that
// dropped the conversion altogether passes this cell; the numbers are
// checked elsewhere, by drawing.
import { test } from 'node:test';
import assert from 'node:assert';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { emitAll } from '../tools/shader-emit.mjs';

const root = new URL('..', import.meta.url).pathname;

// pow( ... 2.2 ... ) or pow( ... 0.4545... ) within one call, in emitted
// GLSL, where a numeric literal prints as written.
const GLSL = /pow\([^;]*?\b(2\.2|0\.4545\d*)\b/g;
// The same pair in Scheme source, where the literal is a string or an
// (fl ...) form, within one line of a (pow ...) form.
const SRC = /\(pow\b[^\n]*?("2\.2"|"0\.4545\d*"|\(fl 2 2\)|\(fl 0 4545\d*\))/g;

const shaders = emitAll().filter(e => !e.name.startsWith('control/'));
const exampleFiles = readdirSync(join(root, 'examples')).filter(f => f.endsWith('.ss')).sort();

test('there are shaders and examples to read', () => {
    assert.ok(shaders.length >= 15, `the emitter produced ${shaders.length} shaders`);
    assert.ok(exampleFiles.length >= 40, `found ${exampleFiles.length} examples`);
});

test('no emitted library shader uses the gamma 2.2 approximation', () => {
    const hits = [];
    for (const e of shaders)
        for (const [part, src] of [['vertex', e.vs], ['fragment', e.fs]])
            for (const m of (src || '').matchAll(GLSL))
                hits.push(`${e.name} ${part}: ${m[0].slice(0, 60)}`);
    assert.deepStrictEqual(hits, [],
        'these shaders convert colour with pow(x, 2.2) or pow(x, 0.4545), an '
        + 'approximation of sRGB; use the sRGB transfer functions:\n  ' + hits.join('\n  '));
});

test('no example uses the gamma 2.2 approximation', () => {
    const hits = [];
    for (const f of exampleFiles) {
        const text = readFileSync(join(root, 'examples', f), 'utf8');
        text.split('\n').forEach((line, i) => {
            if (/^\s*;/.test(line)) return;
            for (const m of line.matchAll(SRC)) hits.push(`examples/${f}:${i + 1}: ${m[0].slice(0, 60)}`);
        });
    }
    assert.deepStrictEqual(hits, [],
        'these examples convert colour with the gamma 2.2 approximation:\n  ' + hits.join('\n  '));
});

// CONTROL.  Both patterns must see the shape they exist to refuse, in the
// spellings this tree actually used, and must not see a 2.2 that is not
// an exponent -- examples/xr-room.ss places a camera at height 2.2.
test('CONTROL the patterns see the approximation and nothing else', () => {
    assert.ok('c = pow(c, vec3(0.4545, 0.4545, 0.4545));'.match(GLSL));
    assert.ok('vec3 base = pow(u_color.rgb, vec3(2.2, 2.2, 2.2));'.match(GLSL));
    assert.ok('(local vec3 base (pow t.rgb (vec3 "2.2" "2.2" "2.2")))'.match(SRC));
    assert.ok('(vec4 (pow c (vec3 "0.4545" "0.4545" "0.4545"))'.match(SRC));
    assert.ok(!'(eye (v3 (fl* 7.0 (flsin a)) 2.2 (fl* 7.0 (flcos a))))'.match(SRC),
        'a coordinate of 2.2 is not a gamma exponent');
    assert.ok(!'vec3 p = vec3(2.2, 0.0, 1.0);'.match(GLSL),
        'a 2.2 outside pow( is not a gamma exponent');
});
