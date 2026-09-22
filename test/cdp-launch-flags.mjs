// withBrowser takes extra launch flags, so a GL question can be asked
// of more than one GL implementation.
//
// Every real-compiler check in this tree ran in front of exactly one
// implementation -- measured, ANGLE's Metal backend on Apple silicon --
// and a reading taken in front of one implementation is a reading about
// that implementation.  A second one is one flag away:
//
//   --use-angle=swiftshader        SwiftShader: software, Vulkan, LLVM
//   --use-gl=swiftshader           no GL context at all
//   --use-angle=swiftshader-webgl  no GL context at all
//
// The last two are why this cell exists as much as the first is.  A
// launch that silently gets no context does not fail: a frame diff of
// two such runs compares nothing with nothing, and reads like agreement.
// So every row that uses a flag first establishes that a context was
// obtained and that the renderer really is a different one.
//
// The rows are in two groups, and the split is the point of the first
// group.  Refusing a bad argument needs no browser, and it must happen
// BEFORE a browser is looked for -- so those rows run with the browser
// made unfindable (GOETEIA_CHROME=none).  A refusal that happened after
// the lookup then answers "no browser" instead of naming flags, which is
// a structural reading of the order.  An earlier version judged "before
// launching" by elapsed time and could not: spawning is asynchronous and
// cheap, so a check placed just after spawn refuses in no measurable
// time with a browser process already started -- shown by a reviewer
// against the real function body with spawn replaced.  An earlier one
// still looked for a leftover profile directory, and was green against
// a withBrowser that launched every time, because withBrowser removes
// its profile on the way out.  Both were green on both sides of the
// question they were meant to ask.
import { test } from 'node:test';
import assert from 'node:assert';
import { findChrome, withBrowser, launchArgs } from '../tools/cdp.mjs';

// ---- no browser needed -------------------------------------------------

async function refusedWithoutBrowser(flags) {
    const saved = process.env.GOETEIA_CHROME;
    process.env.GOETEIA_CHROME = 'none';
    try {
        let ran = false;
        await withBrowser(() => { ran = true; }, { flags });
        return { threw: false, ran };
    } catch (e) {
        return { threw: true, message: String(e && e.message),
                 name: e && e.constructor && e.constructor.name };
    } finally {
        if (saved === undefined) delete process.env.GOETEIA_CHROME;
        else process.env.GOETEIA_CHROME = saved;
    }
}

// A single string is refused rather than wrapped: '--a --b' would be
// ambiguous, and spreading a string passes one argument per CHARACTER --
// 23 of them for --use-angle=swiftshader.  The rest are the ways a
// validator that looks at less than the whole array stays green: a bad
// element after a good one, holes, nesting, and the falsy values a
// "treat falsy as absent" shortcut would admit.
const HOLE = [];
HOLE[1] = '--use-angle=swiftshader';
const BAD = [
    ['a string', '--use-angle=swiftshader'],
    ['null', null], ['false', false], ['0', 0], ['7', 7], ['{}', {}],
    ['[1]', [1]], ['[null]', [null]], ['[undefined]', [undefined]],
    ['a nested array', [['--use-angle=swiftshader']]],
    ['a bad element after a good one', ['--use-angle=swiftshader', 1]],
    ['an array with a hole', HOLE],
];

for (const [label, bad] of BAD) {
    test(`flags as ${label} is refused before a browser is looked for`, async () => {
        const r = await refusedWithoutBrowser(bad);
        assert.ok(r.threw, 'it was accepted' + (r.ran ? ', and the callback ran' : ''));
        assert.match(r.message, /flags/,
            `refused with "${r.message}" (${r.name}), which does not name flags: the `
            + 'browser lookup ran first, so a bad argument costs a launch attempt '
            + 'before it is reported');
    });
}

// A CALLER MAY NOT RESTATE A SWITCH THE LAUNCHER OWNS.  Chrome takes the
// LAST occurrence of a repeated switch -- measured with --use-angle in
// both orders -- so wherever the caller's flags go, one side silently
// wins.  After the fixed list, a caller's --password-store brings back
// the Keychain prompt that stalls a launch for 30 s, and a caller's
// --user-data-dir makes Chrome use a directory that is not the one
// withBrowser later removes.  Before it, the caller's intent silently
// does nothing.  Refusing the collision is loud in both directions.
//
// The owned set is read from launchArgs, the function whose result is
// handed to spawn, and not from a list kept here: a second list of names
// is a second place to add a switch, and the forgotten one is always the
// second.
const owned = launchArgs('/tmp/x')
    .filter(a => a.startsWith('--'))
    .map(a => a.split('=')[0]);

test('the launcher reports the switches it owns', () => {
    assert.ok(owned.length >= 5, `launchArgs yielded ${owned.length} switches`);
    for (const must of ['--headless', '--user-data-dir', '--password-store'])
        assert.ok(owned.includes(must), `${must} is not among them`);
});

for (const name of owned) {
    test(`restating ${name} is refused before a browser is looked for, by name`, async () => {
        const r = await refusedWithoutBrowser([`${name}=caller`]);
        assert.ok(r.threw, `a caller restating ${name} was accepted`);
        assert.ok(r.message.includes(name),
            `refused with "${r.message}", which does not name ${name}`);
    });
}

// The launcher's positional argument is the page every check runs in;
// a second one would open a second page.
test('a positional argument from the caller is refused', async () => {
    const r = await refusedWithoutBrowser(['about:blank']);
    assert.ok(r.threw && /flags/.test(r.message), `got ${JSON.stringify(r)}`);
});

// ---- needs a browser ---------------------------------------------------

const PAGE = `(() => {
    const c = document.createElement('canvas');
    const gl = c.getContext('webgl2') || c.getContext('webgl');
    const e = gl && gl.getExtension('WEBGL_debug_renderer_info');
    return { w: innerWidth, h: innerHeight,
             renderer: gl ? String(e ? gl.getParameter(e.UNMASKED_RENDERER_WEBGL)
                                     : gl.getParameter(gl.RENDERER)) : null };
})()`;
const body = page => page.evaluateInNewPage(PAGE);

if (!findChrome()) {
    console.log('NOT EXERCISED HERE (no Chrome beside this tree; the rows that launch '
        + 'a browser -- that a flag reaches it, that several do, in order -- cannot '
        + 'run.  The refusal rows above ran anyway: they need no browser)');
} else {
    console.log('EXERCISED HERE: withBrowser launched with and without extra flags');

    // Every spelling a caller in the tree uses today: no options at all
    // (test/gfx-tint-alpha.mjs, the self-check in tools/cdp.mjs), options
    // without flags (rt/verify.mjs passes timeoutMs 120000), and the two
    // ways of saying "none".  All must reach the same implementation.
    const plain = await withBrowser(body);
    const same = {
        'timeoutMs only': await withBrowser(body, { timeoutMs: 120000 }),
        'flags: undefined': await withBrowser(body, { flags: undefined }),
        'flags: []': await withBrowser(body, { flags: [] }),
    };
    const soft = await withBrowser(body, { flags: ['--use-angle=swiftshader'] });
    const two = await withBrowser(body,
        { flags: ['--window-size=900,700', '--use-angle=swiftshader'] });
    const lastWins = await withBrowser(body,
        { flags: ['--use-angle=metal', '--use-angle=swiftshader'] });
    const none = await withBrowser(body, { flags: ['--use-gl=swiftshader'] });

    test('with no options at all there is a GL context, as there always was', () => {
        assert.ok(plain.renderer, 'the default launch produced no GL context');
    });

    test('every way of passing no flags reaches the same implementation', () => {
        for (const [k, r] of Object.entries(same))
            assert.strictEqual(r.renderer, plain.renderer, `${k} reached ${r.renderer}`);
    });

    // Both halves are needed: a context, and a renderer that is not the
    // default one.  Either alone reads the same as "the flag was ignored".
    test('the software flag reaches a different implementation', () => {
        assert.ok(soft.renderer, 'with --use-angle=swiftshader there was no GL context');
        assert.match(soft.renderer, /SwiftShader/);
        assert.notStrictEqual(soft.renderer, plain.renderer);
    });

    // Two flags with two independently visible effects.  Forwarding only
    // the first, only the ones it recognises, or joining them into one
    // argument each loses one of the two.  The window size is measured
    // to show in the page: 900,700 is not the default viewport.
    test('every flag in the array reaches the browser', () => {
        assert.match(String(two.renderer), /SwiftShader/, 'the second flag did not arrive');
        assert.ok(two.w !== plain.w || two.h !== plain.h,
            `the viewport is ${two.w}x${two.h}, as without flags: the first flag did not arrive`);
    });

    // Chrome takes the last of a repeated switch, so the caller's order is
    // observable.  Reversing or sorting the array flips this.
    test('the caller\'s order is kept', () => {
        assert.match(String(lastWins.renderer), /SwiftShader/,
            `metal then swiftshader gave ${lastWins.renderer}; the order was changed`);
    });

    // A reading that does not ignore the absence of a context.  If this
    // ever answered a string for a launch with no context, every row above
    // would be believing something it had not established.
    test('CONTROL a spelling that gets no context is seen as one', () => {
        assert.strictEqual(none.renderer, null,
            `--use-gl=swiftshader answered ${JSON.stringify(none.renderer)}; it is measured `
            + 'to give no context');
    });
}
