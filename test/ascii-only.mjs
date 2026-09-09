// The comments in this library are English, and this is what says so.
//
// ⭐ COMMENTS, NOT TEXT.  Several files carry CJK on purpose and must:
// examples/chat.ss demonstrates line-breaking between ideographs,
// test/sexpr-mjs.mjs round-trips unicode, test/args.mjs passes
// non-ASCII argv, and the REPL cell displays a CJK string because that
// is the defect it measures.  A blanket ban on the characters would
// forbid testing the thing the library is supposed to do.  ⇒ The rule
// is about the language a comment is WRITTEN IN, so the check reads
// comments and leaves data alone.
//
// ⚠️ WHAT IT DOES NOT COVER, said rather than implied.  It reads
// WHOLE-LINE comments -- a line whose first non-space character opens
// a comment.  A trailing comment after code needs a scanner that knows
// where a string ends, and this tree already has six hand-written
// partial ones that all get that wrong; adding a seventh to police a
// style rule is a bad trade.  ⇒ Chinese in a trailing comment passes
// here.  That is a known hole with a stated reason, not an oversight.
//
// ⚠️ ONE EXEMPTION, and it is a real one rather than a convenience.
// A .ss test's first line reads `;; expect: <output>` -- it opens with
// a comment marker and run-tests.sh parses it as the expected stdout.
// ⇒ It is data wearing a comment's clothes, and test/utf8-display.ss
// necessarily expects CJK output.  The exemption is by SHAPE (the
// expect line) rather than by filename, so a new UTF-8 test needs no
// edit here and an ordinary comment in that same file is still caught.
//
// ⚠️ IT READS UNTRACKED FILES TOO, and that was a defect for the first
// few hours of this file's life.  It listed `git ls-files` only, with a
// comment saying untracked files were "out of scope by design" because
// review/ and the scratch directories are Chinese throughout.  ⭐ That
// sentence described a different exclusion than the one it performed:
// what it actually hid was every NEW SOURCE FILE IN FLIGHT -- a file
// being ported into the tree right now is untracked, is about to be
// committed, and was invisible.  Measured: a new library with a Chinese
// comment passed all three cells.
//
// ⇒ Untracked files are read when their extension is one this rule
// covers.  That is what keeps review/ out: it carries .md and .json,
// which are not in the map, so the exclusion follows from the rule
// rather than from a list of directories nobody will maintain.
//
// ⭐ Why a check at all, when the tree is already clean: the rule has
// been kept by people remembering it, and a comment in the wrong
// language reads perfectly to whoever wrote it.  The first sweep for
// this answer used `grep -qP` on macOS, where BSD grep does not
// support it and answers "no match" for every file -- so the tree was
// reported clean by an instrument that had looked at nothing.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const HAN = /[぀-ヿ㐀-䶿一-鿿豈-﫿]/;

// a whole-line comment, per language
const OPENER = {
    '.ss': /^\s*;/, '.sls': /^\s*;/, '.sps': /^\s*;/,
    '.mjs': /^\s*(\/\/|\*|\/\*)/, '.js': /^\s*(\/\/|\*|\/\*)/,
    '.sh': /^\s*#/, '.py': /^\s*#/,
};

function tracked() {
    const listed = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' })
        .split('\n').filter(Boolean);
    // ...and anything not yet added, which is where a port lives
    const untracked = execFileSync('git', ['ls-files', '--others', '--exclude-standard'],
                                   { cwd: root, encoding: 'utf8' })
        .split('\n').filter(Boolean);
    return [...listed, ...untracked];
}

test('every comment in the tree is written in English', () => {
    const bad = [];
    for (const f of tracked()) {
        const open = OPENER[path.extname(f)];
        if (!open) continue;
        let s;
        try { s = fs.readFileSync(path.join(root, f), 'utf8'); } catch { continue; }
        s.split('\n').forEach((line, i) => {
            if (i === 0 && /^;;\s*expect:/.test(line)) return;   // an expectation, not prose
            if (open.test(line) && HAN.test(line)) bad.push(`${f}:${i + 1}  ${line.trim()}`);
        });
    }
    assert.deepEqual(bad, [],
        'these comments are not in English; this library is read by people ' +
        'who do not read Chinese:\n  ' + bad.join('\n  '));
});

test('CONTROL the check sees a comment that has it, and not a string that does', () => {
    // ⭐ A check reporting nothing is indistinguishable from a check
    // looking at nothing -- which is exactly how the first sweep for
    // this went wrong.
    const ss = OPENER['.ss'], js = OPENER['.mjs'];
    const cjk = String.fromCodePoint(0x4e2d, 0x6587);
    assert.ok(ss.test(`;; a comment with ${cjk}`) && HAN.test(`;; a comment with ${cjk}`));
    assert.ok(js.test(`// a comment with ${cjk}`) && HAN.test(`// a comment with ${cjk}`));
    assert.ok(!ss.test(`(display "${cjk}")`), 'a string of data is not a comment line');
    assert.ok(!HAN.test(';; an ordinary comment -- with an arrow and a star'));
    // ⭐ and the exemption must be narrow: only line 1, only that shape
    assert.ok(/^;;\s*expect:/.test(';; expect: anything'));
    assert.ok(!/^;;\s*expect:/.test(';; a comment that mentions expect:'));
});

test('CONTROL the file list and the extension map both reach the tree', () => {
    // ⚠️ Either one coming up empty would make the first test pass for
    // the wrong reason.
    const files = tracked();
    assert.ok(files.length > 100, 'the tracked-file list looks wrong');
    assert.ok(files.filter(f => OPENER[path.extname(f)]).length > 100,
              'no commentable files matched the extension map');
});
