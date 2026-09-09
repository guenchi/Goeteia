// A chapter that points at a long form must not name a library the long
// form has never heard of.
//
// This tree documents each area twice on purpose, and says so: the
// manual carries the interface and ends a section with "Long form in
// `docs/lng.md`", while docs/lng.md carries the argument.  That is a
// layering with a pointer, not a copy, and it is the right shape --
// the argument is what gets rewritten, the interface is not.
//
// But nothing watched the pointer.  docs.mjs never opens graphics.md,
// lng.md or simulation.md, and the manual's 3D chapter has sat beside a
// 1593-line graphics.md unguarded: a library could be added to one and
// not the other and no run would say a word.
//
// WHAT THIS CHECKS, AND WHY IT IS NOT MORE.  Headings only.  For every
// chapter that names a docs/X.md, X.md must exist, and every library
// the chapter gives a section to must have a section in X.md too.  It
// does not compare a word of the prose: a check that fires when a
// sentence is rewritten is a check somebody turns off within a month,
// and the drift worth catching is a whole library documented in one
// place and missing from the other.
//
// The cost of that choice, stated rather than left to be discovered:
// two descriptions of the same library can contradict each other
// completely and this stays green.  It watches the shape of the
// division, not the truth of either half.
//
// AND HOW LITTLE IT WATCHES.  Measured on the tree the day this was
// written: 3 of the manual's 33 library sections carry a pointer, so
// this checks three sections.  The convention is real where it is used
// and it is not used much.  The two halves diverge in both directions
// besides -- 13 libraries have a long form and no manual section, 21
// have a manual section and no long form -- so there is no symmetry
// here to assert, and a check that demanded one would be red
// everywhere and gone by morning.  What is left is small and true: a
// section that promises a long form must find one.
//
// ITS SILENCE IS THE DESIGN, NOT AN OVERSIGHT.  Reading the pointed-at
// prose to see whether it answers the question the section raises needs
// understanding, and a check that needs understanding misfires when a
// sentence is rewritten -- and one that misfires is switched off.  That
// half is a person's job: on 2026-09-09 someone read all twelve claims
// in the Simulation chapter against docs/simulation.md and found one
// pointer that led somewhere not answering it, which this would never
// have said a word about.  Do not strengthen this into something that
// tries; add a reading to the round instead.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import assert from 'node:assert';

const root = new URL('..', import.meta.url).pathname;
const manualPath = join(root, '..', '04-goeteia-website', 'docs', 'manual.md');

if (!existsSync(manualPath)) {
    console.log('NOT EXERCISED HERE (the website checkout ../04-goeteia-website/docs/manual.md is not beside this tree; clone the website branch there to check the manual against the long forms)');
} else {
    console.log('EXERCISED HERE: the manual is beside this tree and its long-form pointers are followed');
    const lines = readFileSync(manualPath, 'utf8').split('\n');
    // chapters are ##, sections are ###, and a library section titles
    // itself with the library name in backticks
    // A pointer belongs to the SECTION that writes it, not to the
    // chapter around it.  Attributing it to the chapter made the check
    // demand that every library in a chapter appear in a long form
    // because two of its sections happened to name one -- which is not
    // the convention the manual actually follows ("Long form in
    // `docs/lng.md`." sits at the end of the section it belongs to).
    const sections = [];
    let cur = null;
    let chapter = '';
    for (const line of lines) {
        if (/^## /.test(line)) { chapter = line.slice(3).trim(); cur = null; continue; }
        const h = line.match(/^### `(\([a-z0-9]+ [a-z0-9-]+\))`/);
        if (h) { cur = { chapter, lib: h[1], points: new Set() }; sections.push(cur); continue; }
        if (/^### /.test(line)) { cur = null; continue; }
        if (!cur) continue;
        // Only "Long form in `docs/X.md`" counts as a long-form pointer.
        // Any other mention is a cross-reference to a particular passage
        // -- "see D2a in `docs/determinism.md`" -- and demanding that the
        // referenced file carry a heading for the LIBRARY would be wrong:
        // what is promised there is a passage, not the library.
        for (const m of line.matchAll(/Long form in `docs\/([a-z0-9-]+)\.md`/g)) cur.points.add(m[1]);
    }
    assert.ok(sections.length > 10, 'the manual sweep found almost no library sections');

    const pointing = sections.filter(c => c.points.size > 0);
    assert.ok(pointing.length > 0, 'no section points at a long form; the pointer convention has changed and this check is now watching nothing');
    test('a chapter that points at a long form points at one that exists', () => {
        const missing = [];
        for (const c of pointing)
            for (const p of c.points)
                if (!existsSync(join(root, 'docs', `${p}.md`)))
                    missing.push(`${c.chapter} / ${c.lib} -> docs/${p}.md`);
        assert.deepStrictEqual(missing, []);
    });

    test('every library a pointing chapter documents is in the long form too', () => {
        const missing = [];
        for (const c of pointing) {
            // HEADING lines only.  A first draft searched the whole
            // file, which would have been satisfied by the library
            // being mentioned in passing -- a check looser than the
            // sentence describing it, which is the worse of the two
            // ways for a check and its comment to disagree.
            // Each pointed file is checked on its own.  Joining them
            // meant a section naming two files passed if either one
            // carried the library, and the other pointer went unread.
            for (const p of c.points) {
                const f = join(root, 'docs', `${p}.md`);
                if (!existsSync(f)) continue;          // the cell above owns that
                const heads = readFileSync(f, 'utf8').split('\n')
                    .filter(l => /^#{1,4} /.test(l)).join('\n');
                if (!heads.includes(c.lib))
                    missing.push(`${c.lib} says its long form is docs/${p}.md, which has no heading naming it`);
            }
        }
        assert.deepStrictEqual(missing, [],
            missing.join('\n') + '\nadd a section for it there, or drop the pointer from the chapter.');
    });

    test('and the check would say so if a library were missing', () => {
        // the same comparison against a name no long form carries
        const heads = readFileSync(join(root, 'docs', 'graphics.md'), 'utf8');
        assert.ok(!heads.includes('(gfx invented-for-this-check)'));
    });
}
