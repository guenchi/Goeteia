// RED ON PURPOSE: two defects in the REPL, both about text the REPL
// itself handles rather than about the language.
//
//   R04  `(+ 1 2) ; note` does not print 3.  It answers
//        "read: list opened at repl line 1 column 14 never closed" --
//        ⭐ and column 14 is past the end of what was typed.  The REPL
//        wraps the input, the trailing comment runs to end of line, and
//        the closing paren it added is inside the comment.
//
//   R03  `(display "你好")` comes back as two ASCII characters.  The
//        bytes the program wrote are decoded as latin1 before the
//        terminal encodes them again.
//
// ⚠️ R04 is the one that costs trust rather than characters.  A REPL
// that mishandles a comment tells the user their expression is
// unbalanced, so the natural response is to look for the missing paren
// in something that has none.
//
// ⭐ R04 is the same family as the dependency scanner (see
// defect-r01-scanner-block-comment.ss): rt/repl.mjs holds two of the
// six hand-written partial lexers, `balance` and `topSpans`, whose
// comment handling is byte-identical to the four in rt/compile.mjs.
// The bug here is not that they mishandle `#|` -- they mishandle `;`
// at the point where the wrapper is closed, which is a different
// mistake in the same undermaintained code.
//
// The controls are the same two cases without the trailing comment and
// without the non-ASCII text, so a red says which half is broken
// rather than "the REPL is broken".
//
// Each case starts a REPL as a subprocess.  Measured, all four
// together: 0.49s with GOETEIA_NO_CACHE=1 and 0.52s warm.  ⚠️ An
// earlier version of this comment said "seconds rather than
// milliseconds" and budgeted the cell around that -- written from
// what starting a REPL sounds like, not from a reading, and wrong by
// about forty times.  The shapes are still chosen so no two test the
// same thing, which is a better reason than cost anyway.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function repl(input) {
    return execFileSync('node', [path.join(root, 'bin/goeteia.mjs'), 'repl'],
                        { cwd: root, input, encoding: 'utf8',
                          stdio: ['pipe', 'pipe', 'pipe'], timeout: 120000 });
}

test('CONTROL an expression with no trailing comment prints its value', () => {
    assert.match(repl('(+ 1 2)\n'), /\b3\b/);
});

test('an expression with a trailing comment prints its value', () => {
    const out = repl('(+ 1 2) ; note\n');
    assert.doesNotMatch(out, /never closed/,
                        'the wrapper\'s closing paren landed inside the comment');
    assert.match(out, /\b3\b/);
});

test('CONTROL ascii output survives', () => {
    assert.match(repl('(display "hi")\n'), /hi/);
});

test('non-ascii output survives', () => {
    assert.match(repl('(display "你好")\n'), /你好/,
                 'the bytes were decoded as latin1 before the terminal encoded them');
});
