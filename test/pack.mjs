// rt/pack.mjs: one .ss in, one self-contained .html out.
//
// The claim a packaged page makes is not "it was written" but "what
// ships is the program you verified".  So the
// assertions here go through the artifact: the module is read back OUT
// of the HTML text and run, and its trace signature is compared with
// the compiled module's -- same frames, same readable state.  "It did
// not throw" would be satisfied by a page that silently draws nothing.
//
// Fixtures are test/pages/: static.ss and gradient.ss must package (a
// DOM page and a drawing page, since the emitted page hosts both), and
// unclosed.ss and trap.ss must not -- one failing before there are any
// bytes to embed, one after, which are different reports.
//
// Truncate or re-encode the payload and the byte-for-byte check goes
// red; break the inlined loader's syntax and the `node --check` of the
// page's own module script goes red.  Neither is reachable by looking
// at the bytes the packager happens to still hold in memory, which is
// why the self-check does not.
//
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { extractWasm, externalRefs, packageFile, renderPage, selfCheck } from '../rt/pack.mjs';

const PAGES = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)), 'pages');
const page = name => path.join(PAGES, name);

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-pack-test-'));
test.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

const failed = r => (r.checks || []).filter(c => !c.ok).map(c => c.detail).join('\n');

test('a DOM page packages into one file that carries the same program', async () => {
    const out = path.join(tmp, 'static.html');
    const r = await selfCheck(page('static.ss'), { outFile: out });
    assert.equal(r.ok, true, failed(r));
    // BY NAME, not by count. `>= 6` was satisfied by eight checks, so
    // any one of five mechanisms could be deleted outright and this
    // stayed green -- including the one that compares the file on disk
    // with the page that was rendered. A count cannot say which member
    // of a family is missing; only the names can.
    assert.deepEqual(r.checks.map(c => c.id),
        ['payload', 'compiled-runs', 'embedded-runs', 'same-trace',
         'on-disk', 'no-literal-fetch', 'module-parses'],
        'every self-check mechanism, in order, and nothing quietly gone');
    assert.ok(fs.existsSync(out), 'the artifact must be on disk');

    const html = fs.readFileSync(out, 'utf8');
    assert.match(html, /<div id="app">/);
    assert.match(html, /<canvas id="c" width="800" height="600">/);
    assert.match(html, /<title>static<\/title>/, 'the title defaults to the base name');
    // Not "nothing is fetched" -- see rt/pack.mjs's header for why that
    // stronger claim is not asserted anywhere.  What is checked is that
    // the module comes off the page rather than from a URL, and that no
    // literal URL appears.  A request assembled at run time would pass
    // all of this; catching that needs a headless load and a network
    // log, which is named as a gap rather than implied to be covered.
    // The loader still CONTAINS the fetch-based entry points it has in
    // rt/web.mjs -- they are simply never reached, because the launch
    // block reads the payload off the page and calls runGoeteiaBytes
    // with it.  What must not appear is a URL to reach for.
    assert.doesNotMatch(html, /\bfetch\s*\(\s*['"`]/, 'no literal URL is fetched');
    assert.doesNotMatch(html, /https?:\/\//);
    assert.doesNotMatch(html, /^\s*import\s/m, 'the loader must be inlined, not imported');
    assert.match(html, /getElementById\("goeteia-module"\)[\s\S]*runGoeteiaBytes\(bytes\)/,
        'the module must come off the page itself');
});

test('a drawing page packages, and the embedded bytes draw the same frames', async () => {
    const r = await selfCheck(page('gradient.ss'), {});
    assert.equal(r.ok, true, failed(r));
    // the same family, minus the one that needs a file on disk
    assert.deepEqual(r.checks.map(c => c.id),
        ['payload', 'compiled-runs', 'embedded-runs', 'same-trace',
         'no-literal-fetch', 'module-parses'],
        'with no outFile, on-disk is the only member that drops out');
    assert.ok(r.stats.draws > 0, 'the self-check ran the page, it did not just parse it');
    assert.ok(r.stats.html_bytes > r.stats.wasm_bytes,
        'base64 plus the loader cannot be smaller than the module');
});

test('a source that does not compile is reported before anything is embedded', async () => {
    const out = path.join(tmp, 'unclosed.html');
    const r = await selfCheck(page('unclosed.ss'), { outFile: out });
    assert.equal(r.ok, false);
    assert.equal(r.stage, 'compile');
    assert.equal(r.checks.length, 0);
    assert.equal(r.errors[0].line, 4, 'the compile diagnostic must survive the trip');
    assert.equal(fs.existsSync(out), false, 'no artifact may be left behind');
});

test('a page that traps is caught by the self-check, not shipped', async () => {
    const r = await selfCheck(page('trap.ss'), {});
    assert.equal(r.ok, false);
    assert.equal(r.stage, 'selfcheck');
    // it packaged fine -- the bytes match -- and then failed to run
    assert.equal(r.checks[0].ok, true, 'the payload itself is intact');
    const ran = r.checks.filter(c => /\bruns?:/.test(c.detail));
    assert.equal(ran.length, 2);
    assert.ok(ran.every(c => !c.ok), 'both the module and the embedded copy must fail');
    assert.match(ran[0].detail, /illegal cast/);
});

test('a truncated payload is caught by reading the artifact back', async () => {
    const p = await packageFile(page('static.ss'), null, {});
    assert.equal(p.ok, true);
    assert.equal(Buffer.compare(extractWasm(p.html), Buffer.from(p.wasm)), 0);

    // the same page rendered around one byte less: this is the shape
    // of every payload defect (a truncated write, a mangled re-encode),
    // and comparing against the in-memory bytes would never see it
    const short = renderPage(p.wasm.subarray(0, p.wasm.length - 1));
    assert.equal(extractWasm(short).length, p.wasm.length - 1);
    assert.notEqual(Buffer.compare(extractWasm(short), Buffer.from(p.wasm)), 0);
});

test('a page with no payload, or a payload that is not base64, is refused', () => {
    assert.throws(() => extractWasm('<html></html>'), /no goeteia\/wasm payload/);
    const bad = renderPage(Buffer.from([0, 1, 2]))
        .replace(/(<script type="goeteia\/wasm" id="goeteia-module">)/, '$1!!');
    assert.throws(() => extractWasm(bad), /not base64/);
});

// A page whose payload is EXACTLY the given text, so a spelling can be
// put on the wire without going through the encoder that would fix it.
const pageWith = (payload) =>
    renderPage(Buffer.from([0, 1, 2]))
        .replace(/(<script type="goeteia\/wasm" id="goeteia-module">)[^<]*/,
                 `$1${payload}`);

// The SHAPE of a packaged page, pinned against a stored copy.
//
// This replaces asking a scanner whether the page names any external
// URL. That scanner had to agree with a browser about arbitrary HTML,
// and four rounds of review found four more documents where it did
// not -- while its only real input was ever a page this file's own
// renderPage produced from a fixed template. The property that
// matters is a property of the TEMPLATE, and a template is a fixed
// string: comparing it is stronger than parsing it, and catches
// everything a scanner cannot -- a CSS url(), a <meta refresh>, a
// changed loader, a dropped CSP, an added attribute.
//
// The other side of the comparison is a stored file, NOT a second
// call to renderPage. Rendering twice and comparing proves only that
// renderPage is deterministic: both sides would carry the same new
// <img src="..."> and agree. `test/pages/golden-shell.html` is the
// approved shape, and approving is what a human does when the diff
// lands.
//
// Parameters are pinned too, because the shell is not parameter-free:
// title and the canvas dimensions appear in it, so the golden is
// generated at title "golden", 800x600, and this test uses exactly
// those. Anything else drifts by a few bytes and the failure would
// look like a template change.
//
// WHY ONE PARAMETER SET IS ENOUGH, and where the other half is. The
// template is fixed at build time, so one rendering pins its shape --
// there is no second template for other titles. What one rendering
// does NOT pin is what happens to the parameters on their way in, and
// that is a different property with its own tests: see "a title is
// escaped on the way into the page" below. Shape here, escaping
// there; neither covers the other.
//
// (This note lives in the test and not in the fixture because the
// fixture is compared byte for byte -- a comment inside it would have
// to appear in the template too, or it would be the difference.)
//
// UPDATING IT: change the golden in the SAME COMMIT as the template
// change, never in a commit of its own. A lone "update golden" says
// nothing about what moved; the two together carry their own cause,
// and the reviewer sees the template diff and its consequence side by
// side rather than a red followed later by a patch.
const PAYLOAD_SLOT = '{{PAYLOAD}}';
const blankPayload = html => html.replace(
    /(<script type="goeteia\/wasm" id="goeteia-module">)[^<]*/,
    `$1${PAYLOAD_SLOT}`);

test('a packaged page has the approved shape, byte for byte', () => {
    const golden = fs.readFileSync(page('golden-shell.html'), 'utf8');
    const rendered = blankPayload(
        renderPage(Buffer.from([0]), { title: 'golden', width: 800, height: 600 }));
    assert.equal(rendered, golden,
        'the page shape changed; if that was intended, update '
        + 'test/pages/golden-shell.html in this same commit');

    // ...and the slot really is where the payload goes, so that the
    // comparison above is over the whole page and not over a page with
    // an arbitrary hole in it
    const real = renderPage(Buffer.from([1, 2, 3]), { title: 'golden', width: 800, height: 600 });
    assert.notEqual(real, golden, 'the golden must not match a page with a payload in it');
    assert.equal(blankPayload(real), golden, 'blanking only the payload restores the shape');
    assert.equal(golden.split(PAYLOAD_SLOT).length - 1, 1, 'exactly one slot');
});

const titleOf = html => html.match(/<title>([\s\S]*?)<\/title>/)[1];
const withTitle = title =>
    renderPage(Buffer.from([0]), { title, width: 800, height: 600 });

test('a title is escaped on the way into the page', () => {
    // Three replacements, three cases: deleting any one of them turns
    // exactly its own line red. Before this, `grep -c "esc(" ` over
    // this file answered 0 -- the escaping was correct and nothing
    // said so, which is the same thing as not having it the day
    // someone edits it.
    assert.equal(titleOf(withTitle('<')), '&lt;', 'less-than');
    assert.equal(titleOf(withTitle('>')), '&gt;', 'greater-than');
    assert.equal(titleOf(withTitle('&')), '&amp;', 'ampersand');

    // ORDER. The ampersand has to go first: replace `<` first and its
    // output `&lt;` is then caught by the ampersand rule and comes out
    // `&amp;lt;`. A test that feeds one character at a time cannot see
    // this -- each single character still looks right -- so the case
    // has to be one whose OUTPUT contains an ampersand.
    assert.equal(titleOf(withTitle('&lt;')), '&amp;lt;',
        'an ampersand already in the input escapes once, not twice');
    assert.equal(titleOf(withTitle('a&b')), 'a&amp;b');

    // ...and the shape all of that exists to stop: a title that tries
    // to close the element and open its own. Asserting the escaped
    // text is not enough on its own -- this asks the question the
    // escaping is FOR, which is whether the document gained a tag.
    const injected = withTitle('</title><img src=https://evil.example/x.png>');
    assert.doesNotMatch(injected, /<img/,
        'a title must not be able to add an element to the document');
    assert.doesNotMatch(injected, /evil\.example[^&]*"/);
    assert.equal(titleOf(injected),
        '&lt;/title&gt;&lt;img src=https://evil.example/x.png&gt;');
});

test('an external reference is found however the attribute is spelled', () => {
    // One rule, and HTML gives it four members: double quotes, single
    // quotes, no quotes, and any casing of the name. The finder used to
    // know only the first, so a shipped page carrying
    // <script src='side.js'> passed the "no external references" claim.
    for (const tag of [
        '<script src="side.js"></script>',
        "<script src='side.js'></script>",
        '<script src=side.js></script>',
        '<SCRIPT SRC="side.js"></SCRIPT>',
        '<link href="side.css">',
        "<img SRC='side.png'>",
    ])
        assert.deepEqual(externalRefs(`<body>${tag}</body>`).length, 1,
            `missed the reference in ${tag}`);

    // ...and the three kinds that reach nothing stay unreported, or the
    // check fires on every correct page and gets switched off.
    for (const tag of [
        '<a href="#top">x</a>',
        '<img src="data:image/gif;base64,AAAA">',
        '<a href="javascript:void 0">x</a>',
        '<a HREF="#top">x</a>',
    ])
        assert.deepEqual(externalRefs(`<body>${tag}</body>`), [],
            `false positive on ${tag}`);

    // The page inlines a runtime, and JS assigns to .src as a property.
    // Scanning the script BODY reports that as a reference: a false red
    // on a page that fetches nothing.
    assert.deepEqual(
        externalRefs('<script type="module">el.src = new URL(x); a.href=y;</script>'),
        [], 'a script body is not markup');

    // The two holes that narrowing the scan to markup opened up. Both
    // were caught by the whole-document version it replaced, so they
    // are regressions of the fix, not of the original -- a check that
    // stops looking somewhere has to be asked what it stopped seeing.
    assert.deepEqual(
        externalRefs('<script data-x=">" src="side.js"></script>'), ['side.js'],
        'a > inside a quoted attribute must not end the opening tag');
    assert.deepEqual(
        externalRefs('<!-- <script> --><img src="side.png"><!-- </script> -->'),
        ['side.png'],
        'script tags inside comments must not pair around real markup');
    // and the should-GREEN side of that same comment handling: markup
    // that is commented out is not fetched, so it is not a reference
    assert.deepEqual(externalRefs('<!-- <img src="never.png"> -->'), [],
        'a reference inside a comment is not a reference');

    // srcset names several URLs in one attribute, each with an optional
    // descriptor; poster is a third attribute that fetches.
    assert.deepEqual(
        externalRefs('<img srcset="a.png 1x, b.png 2x">'), ['a.png', 'b.png'],
        'every candidate in a srcset is a reference');
    assert.deepEqual(externalRefs('<video poster="p.jpg">'), ['p.jpg'],
        'poster fetches too');

    // Every row below is a document where this function and a browser
    // disagreed. They are grouped because the shape repeats: each is
    // some construct the HTML parser handles that a stricter reader
    // does not, and the two directions are NOT equally bad -- a false
    // negative ships a page that reaches the network, a false positive
    // gets the check switched off. Both are pinned.
    for (const [html, want, why] of [
        // ...it stops looking (false negatives)
        ['<!--><img src="x.png">', ['x.png'],
         'an abrupt-closing empty comment ends there; it has no -->'],
        ['<!---><img src="x.png">', ['x.png'],
         'and so does the one with the extra dash'],
        ['<script>0</script x><img src="x.png">', ['x.png'],
         'an end tag may carry attributes; it still closes'],
        ['<script>0</script/><img src="x.png">', ['x.png'],
         'and it may carry a solidus'],
        // ...it looks where a browser does not (false positives)
        ['<textarea><img src="x.png"></textarea>', [],
         'textarea holds text, not markup'],
        ['<title><img src="x.png"></title>', [], 'and so does title'],
        ['<div data-src="x.png"></div>', [],
         'data-src is a different attribute; \\b is not a name boundary'],
        ['<div data-href="x.png"></div>', [], 'nor is data-href'],
        ['<div data-srcset="x.png 1x"></div>', [], 'nor data-srcset'],
        // HTML has no self-closing script: the element stays open, so
        // what follows is script text and is never fetched
        ['<script src="a.js"/><img src="x.png">', ['a.js'],
         'a script tag does not self-close'],
        // The end tag needs the same quote awareness as the opening
        // one: the fix for `<script data-x=">" ...>` was applied to one
        // half of the pair and not the other.
        ['<script>0</script x="><img src=x.png>">', [],
         'a > inside a quoted end-tag attribute does not end it'],
        ['<script>0</scriptfoo><img src="x.png"></script><img src="y.png">',
         ['y.png'], '</scriptfoo> is not an end tag for script'],
        // The four text-holding elements, one TAG-SHAPED probe each.
        // A probe has to be shaped like markup to discriminate: this
        // function collects tags and ignores document text, so
        // `<style>src=x.png</style>` is refused by the mutant too and
        // pins nothing. (That was the first probe written here, and it
        // could not fail -- the review that reported this branch got
        // the direction right and the example wrong, and repeating the
        // example would have added a green row that asserts nothing.)
        // Each of these reddens when, and only when, its own element is
        // dropped from the raw-element list.
        //
        // WHAT THE COVERAGE ACTUALLY WAS BEFORE THIS.  The message of
        // 2450f4c says no case could tell the four apart, which is too
        // wide.  Read out of `git show 738d6f3:test/pack.mjs`:
        //
        //   style      no case at all -- not a weak probe, none.  That
        //              is why dropping style was the one mutation that
        //              survived.
        //   textarea   pinned on purpose: the tag-shaped probes above
        //   title      were already there.
        //   script     pinned by accident, by
        //              `<script src="a.js"/><img src="x.png">`, whose
        //              expected value excludes the image: stop treating
        //              script as raw text and the image appears.
        //
        // This paragraph is itself a claim about a revision, so it was
        // written by reading that revision and then sent to review with
        // "check it against 738d6f3 rather than trusting it".  An
        // earlier draft, written from what the file looks like NOW,
        // named two probes that revision does not contain -- and it had
        // already been read and agreed with twice before the check
        // caught it.  A sentence about the past cannot be reviewed by
        // people who remember the past; it has to be diffed.
        //
        // Written here rather than as a correction to the commit
        // message because this is where a reader of these probes is,
        // and because a published history is not rewritten to fix a
        // sentence.
        ['<style><img src="x.png"></style>', [], 'a style body is text'],
        ['<title><img src="x.png"></title>', [], 'so is a title'],
        ['<textarea><img src="x.png"></textarea>', [], 'so is a textarea'],
        ['<script><img src="x.png"></script>', [], 'so is a script'],
        ['<style>a{background:url(bg.png)}</style><img src="x.png">',
         ['x.png'], 'CSS url() is outside what this scans, by name'],
        // A custom element whose name merely BEGINS with one of the
        // four is an ordinary element. `\\b` said otherwise, which is
        // the same thing `\\b` got wrong about data-src -- one rule,
        // two places, and only one of them had been fixed.
        ['<script-x><img src="x.png"></script-x>', ['x.png'],
         'script-x is a custom element, not a script'],
        ['<style-x><img src="x.png"></style-x>', ['x.png'], 'nor style-x'],
        ['<textarea-x><img src="x.png"></textarea-x>', ['x.png'],
         'nor textarea-x'],
        ['<title-x><img src="x.png"></title-x>', ['x.png'], 'nor title-x'],
        // srcset takes the same three quotings as any attribute; only
        // the double-quoted one was exercised, so narrowing the value
        // pattern to `"[^"]*"` stayed green.
        ["<img srcset='a.png 1x, b.png 2x'>", ['a.png', 'b.png'],
         'a single-quoted srcset'],
        ['<img srcset=a.png>', ['a.png'], 'an unquoted srcset'],
        ['<img SRCSET="a.png 1x">', ['a.png'], 'and any casing of it'],
    ])
        assert.deepEqual(externalRefs(html), want, `${why}: ${html}`);
});

test('KNOWN DISAGREEMENTS: what this scanner gets wrong, on purpose', () => {
    // ⚠ EVERY ROW BELOW IS WRONG. They are pinned so the record of how
    // HTML actually parses stays complete, and so that a future reader
    // who finds one of them does not think it is new. Nothing here is
    // approved behaviour -- read this section as "known bugs, with the
    // reason they are not fixed", never as an example to copy.
    //
    // They are in a section of their own rather than mixed into the
    // table above with a wording that says "wrong", because a reader
    // skimming one long table takes every row as a statement of
    // correct behaviour; a heading is harder to skim past than an
    // adjective.
    //
    // WHY NOT FIXED: this function is no longer a gate. Nothing ships
    // or fails on what it returns -- selfCheck compares the page
    // against an approved shape instead. Fixing these means bringing
    // back the thing that was removed: parsing arbitrary HTML, here
    // down to the tokenizer's comment states and to knowing which part
    // of a tag a match landed in. That was four rounds of one more
    // document each, and the price was paid to stop.
    for (const [html, ours, browser, why] of [
        ['<!-- --!><img src="x.png">', [], ['x.png'],
         'the tokenizer closes a comment at --!> from the comment-end-bang '
         + 'state; this only looks for -->, so it eats the rest'],
        ['<div title="src=side.png"></div>', ['side.png'], [],
         'the attribute pattern does not know where in a tag it matched, '
         + 'so a value that reads like an attribute is taken for one'],
    ]) {
        assert.deepEqual(externalRefs(html), ours,
            `this row records CURRENT behaviour; a browser says `
            + `${JSON.stringify(browser)} -- ${why}`);
        assert.notDeepEqual(ours, browser,
            'if these ever agree, the row is stale: delete it');
    }
});

test('the payload has to be canonical base64, not merely decodable', () => {
    // Buffer.from(x, 'base64') takes all of these: it skips characters
    // it does not know, does not mind a length off a multiple of four,
    // and ignores what the padding claims. Each spelling below is one
    // of the ways a payload can be wrong while still "decoding", and
    // our own encoder emits none of them -- so seeing one means the
    // page was edited or damaged, and decoding it anyway turns a
    // truncated payload into a wasm module that fails somewhere later.
    for (const [payload, why] of [
        // the unused-bit rule has two members, one for each padding
        // length: one '=' leaves two unused bits, two leave four. Only
        // the first was here, so the two-'=' mask could be dropped
        // altogether and every line still passed. 'AB==' decodes to
        // the same byte as the canonical 'AA=='.
        ['AAB=', 'the bits the padding says are unused are not zero'],
        ['AB==', 'the same, at the other padding length'],
        ['A===', 'three pad characters, which no encoding produces'],
        ['=AAA', 'padding at the front'],
        ['AA=A', 'padding in the middle'],
        ['AA==AAAA', 'padding in the middle of a longer payload'],
        // three wrong residues, not one: with only the 3 case here,
        // relaxing the rule to `length % 2` kept the whole table green
        // while 'AA' -- a truncation of exactly one character -- got in.
        ['A', 'a length of one past the group'],
        ['AA', 'a length of two past the group'],
        ['AAA', 'a length that is not a multiple of four'],
        ['AA A=', 'whitespace inside the payload'],
        ['AA\nA=', 'a newline inside the payload'],
        ['AA-A', 'a character outside the alphabet'],
    ])
        assert.throws(() => extractWasm(pageWith(payload)), /not base64/,
            `accepted "${payload}": ${why}`);

    // ...and the three canonical shapes go through, each to the bytes
    // it spells. Without these the check above would be satisfied by a
    // reader that refused everything.
    for (const [payload, bytes] of [
        ['AA==', [0]],
        ['AAA=', [0, 0]],
        ['AAAA', [0, 0, 0]],
        ['/w==', [255]],
        // both of the two non-alphanumeric characters: '/' above, '+'
        // here. Nothing else in the valid table reaches '+', so an
        // alphabet that had lost it would still pass every other line.
        ['+/8=', [251, 255]],
        ['AQID', [1, 2, 3]],
        ['', []],
        // whitespace AROUND the payload is trimmed and accepted: it is
        // outside the token, and an HTML tool reindenting around the
        // tag is a benign thing to survive. Whitespace inside it is
        // refused above -- that is the token itself being rewritten.
        [' AAA=', [0, 0]],
        ['AAA= ', [0, 0]],
        ['\nAAA=\n', [0, 0]],
        ['  ', []],
    ])
        assert.deepStrictEqual(Array.from(extractWasm(pageWith(payload))), bytes,
            `"${payload}" did not decode to what it spells`);
});
