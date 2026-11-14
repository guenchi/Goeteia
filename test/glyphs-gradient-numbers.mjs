// (web glyphs) samples a gradient heading's colour per glyph from the
// numbers in its computed background-image (ledger R87, batch M49): the
// maximal runs of the digits 0 to 9, each a decimal integer, in order --
// what /\d+/g with Number gave when it was a function made with js-eval.
// The last six numbers are the two stops' r g b.  And glyphs-track!
// observes the document with childList and subtree true.
//
// A stub DOM: the heading is 100px wide, every glyph 10px, so the glyph
// centres sit at 5, 15, 25 and 35px and the colour of each is the stop
// interpolated at x / 100, truncated.  Two gradients: plain rgb() stops,
// and stops with percentages, where the digit runs make the last six
// numbers 30 0 110 120 130 100 -- a strange colour, pinned because it is
// what the rule gives.
//
// The file runs twice, as the other R87 cells do: as it is, and under
// --disallow-code-generation-from-strings.  Both targets each time.
//
// ON THE TREE BEFORE THE CHANGE the plain run is green (the colours were
// already these) and the run under the flag fails: (web js) evaluates
// "true" when it loads.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const FLAG = '--disallow-code-generation-from-strings';
const here = fileURLToPath(import.meta.url);
const root = fileURLToPath(new URL('..', import.meta.url));
const mode = process.argv[2];

if (mode === undefined) {
    const env = { ...process.env };
    delete env.NODE_TEST_CONTEXT;
    let bad = 0;
    for (const [m, flags] of [['plain', []], ['no-eval', [FLAG]]]) {
        const r = spawnSync(process.execPath, [...flags, here, m],
                            { env, encoding: 'utf8' });
        process.stdout.write(r.stdout || '');
        process.stderr.write(r.stderr || '');
        if (r.status !== 0) {
            console.error(`FAIL the ${m} run exited ${r.status}`);
            bad = 1;
        }
    }
    process.exit(bad);
}

if (mode === 'no-eval') {
    assert.throws(() => eval('1'), EvalError);
} else {
    assert.equal(eval('1'), 1);
}

const { compileSource } = await import('../rt/compile.mjs');
const { runModule } = await import('../rt/run.mjs');
const { runJsModule } = await import('../rt/runjs.mjs');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-glyphs-'));
process.on('exit', () => fs.rmSync(dir, { recursive: true, force: true }));

const PLAIN = 'linear-gradient(120deg, rgb(21, 80, 196), rgb(71, 136, 238))';
const PERCENT = 'linear-gradient(90deg, rgb(10, 20, 30) 0%, rgb(110, 120, 130) 100%)';
const WANT = {
    [PLAIN]: [[23, 82, 198], [28, 88, 202], [33, 94, 206], [38, 99, 210]],
    [PERCENT]: [[34, 6, 109], [43, 19, 108], [52, 32, 107], [61, 45, 106]],
};

// a stub DOM: enough of an element, a canvas and a computed style
let heading = null;
let observed = [];
function element(tag) {
    const el = {
        tagName: String(tag).toUpperCase(), children: [], attrs: {},
        style: {}, text: '', innerHTML: '',
        setAttribute(n, v) { this.attrs[n] = String(v); },
        getAttribute(n) { return this.attrs[n] ?? null; },
        appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
        removeChild(c) { this.children = this.children.filter(x => x !== c); return c; },
        getBoundingClientRect() {
            const width = this === heading ? 100 : 10 * [...this.text].length;
            return { left: 0, top: 0, width, height: 20 };
        },
        getContext() {
            return { font: '', measureText: s => ({ width: 10 * [...String(s)].length }) };
        },
        addEventListener() {}, removeEventListener() {},
    };
    Object.defineProperty(el, 'textContent', {
        get() { return el.text; },
        set(v) { el.text = String(v); el.children = []; },
    });
    return el;
}
function install(gradient) {
    heading = element('h1');
    heading.textContent = 'ABCD';
    observed = [];
    const style = {
        color: 'rgba(0, 0, 0, 0)', backgroundImage: gradient,
        fontSize: '16px', lineHeight: '20px', letterSpacing: 'normal',
        textAlign: 'left', fontStyle: 'normal', fontWeight: '400',
        fontFamily: 'serif',
    };
    globalThis.testHeading = heading;
    globalThis.document = { createElement: element };
    globalThis.getComputedStyle = el => el === heading ? style
        : { ...style, backgroundImage: 'none', color: 'rgb(0, 0, 0)' };
    globalThis.addEventListener = () => {};
    globalThis.removeEventListener = () => {};
    globalThis.requestAnimationFrame = () => 1;
    globalThis.MutationObserver = class {
        constructor(callback) { this.callback = callback; }
        observe(target, options) { observed.push(options); }
        disconnect() {}
    };
}
const colours = () => heading.children
    .map(c => /color:rgb\((\d+),(\d+),(\d+)\)/.exec(c.attrs.style || ''))
    .filter(Boolean)
    .map(m => [Number(m[1]), Number(m[2]), Number(m[3])]);

const source = '(import (rnrs) (web js) (web glyphs))\n' +
    '(define g (glyphs! (js-get (js-global) "testHeading")))\n' +
    '(glyphs-track! (list g))\n' +
    '(display "ok")\n';
const wasm = await compileSource(source, { baseDir: root });
const js = await compileSource(source, { baseDir: root, target: 'js' });
const jsFile = path.join(dir, 'glyphs.mjs');
fs.writeFileSync(jsFile, js);

const failures = [];
for (const target of ['wasm', 'js']) {
    for (const gradient of [PLAIN, PERCENT]) {
        install(gradient);
        let text;
        try {
            text = target === 'wasm' ? (await runModule(wasm)).text
                                     : (await runJsModule(jsFile)).text;
        } catch (e) {
            failures.push(`${target} ${gradient}: ${e.constructor.name}: ${e.message}`);
            continue;
        }
        const got = colours();
        if (text.trim() !== 'ok')
            failures.push(`${target} ${gradient}: printed ${JSON.stringify(text)}`);
        try {
            assert.deepEqual(got, WANT[gradient]);
        } catch {
            failures.push(`${target} ${gradient}: colours ${JSON.stringify(got)}, ` +
                          `want ${JSON.stringify(WANT[gradient])}`);
        }
        if (observed.length !== 1 || observed[0].childList !== true ||
            observed[0].subtree !== true)
            failures.push(`${target}: observe got ${JSON.stringify(observed)}`);
    }
}

if (failures.length) {
    console.error(`FAIL (${mode}):`);
    for (const f of failures) console.error('  ' + f);
    process.exit(1);
}
console.log(`ok (${mode}): gradient colours from $numbers and the observer options, wasm and js`);
