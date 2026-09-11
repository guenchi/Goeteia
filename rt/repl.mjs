// Copyright 2026 guenchi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// The Goeteia REPL: each evaluation compiles the accumulated
// definitions plus the new input as one program (through the same
// self-hosted compiler as everything else) and runs it fresh.
//
// Semantics that follow from that: definitions persist BY REPLAY --
// a (define x (begin (display "!") 1)) re-runs its initialiser on
// every subsequent evaluation -- and plain expressions are one-shot.
// This trades instantaneous state for the property that what you
// build in the REPL is exactly a program: paste the definitions into
// a .ss file and it behaves identically.
//

import readline from 'readline';
import { compileSource } from './compile.mjs';
import { runModule } from './run.mjs';

// paren balance, aware of strings, comments and char literals
// One place that knows what is not code.
//
// Six hand-written walkers -- four in compile.mjs, two here -- each
// carried the same three lines for `;`, `"` and `#\`, byte for byte,
// and none of them knew `#|`.  So an (import ...) written inside a
// block comment was found by libraryImports and taken for the
// library's real import list: the reader discards that clause, the
// scanner obeys it, and the build fails on a dependency the source
// does not have.  They had not drifted apart -- they were copied
// already incomplete, which is why one function replaces six edits.
//
// Answers the index of the LAST character of the non-code token
// starting at i, so a caller inside a `for (i...)` loop can write
// `i = noiseEnd(...); continue;` and let its own i++ step past.
// Answers -1 when code begins at i.
//
// `#;` is deliberately not here.  Skipping a datum comment means
// finding where a datum ends, which is a reader's job and not a
// scanner's -- and measured, it is not reachable: `#;(import (x))`
// compiles today.  Adding datum-skipping would be a new mechanism
// bought for a case nobody has.
//
// An unclosed `#|` or `"` runs to the end of the text rather than
// raising: these scanners only decide where forms are, and the reader
// that comes after refuses the file by itself.
function noiseEnd(text, i) {
    const c = text[i];
    if (c === ';') {
        while (i < text.length && text[i] !== '\n') i++;
        return i;
    }
    if (c === '"') {
        i++;
        while (i < text.length && text[i] !== '"') { if (text[i] === '\\') i++; i++; }
        return i;
    }
    if (c === '#' && text[i + 1] === '\\') return i + 2;
    if (c === '#' && text[i + 1] === '|') {
        let depth = 1;
        i += 2;
        while (i < text.length && depth > 0) {
            if (text[i] === '#' && text[i + 1] === '|') { depth++; i += 2; }
            else if (text[i] === '|' && text[i + 1] === '#') { depth--; i += 2; }
            else i++;
        }
        return i - 1;
    }
    if (c === '|') {
        i++;
        while (i < text.length && text[i] !== '|') i++;
        return i;
    }
    return -1;
}

function balance(text) {
    let depth = 0;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        { const j = noiseEnd(text, i); if (j >= 0) { i = j; continue; } }
        if (c === '(') depth++;
        else if (c === ')') depth--;
    }
    return depth;
}

// Whether a stretch of text holds anything the compiler would read.
// Comments and whitespace are characters without being code, and the
// difference decides whether a tail is a bare atom or a leftover note.
function hasCode(text) {
    for (let i = 0; i < text.length; i++) {
        const j = noiseEnd(text, i);
        if (j >= 0) { i = j; continue; }
        if (!/\s/.test(text[i])) return true;
    }
    return false;
}

// top-level form spans (same scanner shape as the balance check)
function topSpans(text) {
    const spans = [];
    let depth = 0, start = -1;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        { const j = noiseEnd(text, i); if (j >= 0) { i = j; continue; } }
        if (c === '(') { if (depth === 0) start = i; depth++; }
        else if (c === ')') { depth--; if (depth === 0) spans.push([start, i + 1]); }
    }
    return spans;
}

const DEFINITION =
    /^\(\s*(define|define-syntax|define-record-type|import|export|library)[\s(]/;

export async function startRepl() {
    const defs = [];
    console.log('Goeteia REPL.  Definitions persist by replay (initialisers');
    console.log('re-run on each evaluation); expressions are one-shot.');
    console.log('Ctrl-D exits.');
    const rl = readline.createInterface({
        input: process.stdin,
        output: process.stdout,
        terminal: process.stdin.isTTY,
    });
    let buf = '';
    let busy = false;
    const queue = [];
    const prompt = () => {
        if (process.stdin.isTTY) {
            rl.setPrompt(buf ? '     ... ' : 'goeteia> ');
            rl.prompt();
        }
    };

    // wrap the last expression so the program itself writes the
    // value (the runner only renders scalars); void stays silent
    function printLast(input) {
        const spans = topSpans(input);
        const wrap = (s) =>
            `(let ((%repl-result ${s}))` +
            ` (unless (eq? %repl-result (if #f #f))` +
            ` (write %repl-result) (newline)))`;
        const tailStart = spans.length ? spans[spans.length - 1][1] : 0;
        const tail = input.slice(tailStart);
        // A bare atom: lst, 42, ...  The test is whether the tail holds
        // CODE, not whether it holds characters: a line comment after
        // the last form is characters and not code, and wrapping it
        // produced `(... %repl-result ; note))`, where the comment ate
        // the parentheses the wrapper had just added.  The reader then
        // reported an unclosed list at a column past the end of what
        // the user typed, which is the tell that the text it failed on
        // was not the text they wrote.
        if (hasCode(tail))
            return input.slice(0, tailStart) + wrap(tail.trim());
        if (spans.length) {
            const [s, e] = spans[spans.length - 1];
            const last = input.slice(s, e);
            if (!DEFINITION.test(last))
                return input.slice(0, s) + wrap(last) + input.slice(e);
        }
        return input;
    }

    async function evaluate(input) {
        try {
            // A REPL session imports (rnrs): a program begins with an
            // import form, and nobody types one at a prompt.  The
            // session is compiled as a program like any other, so
            // without this the empty map refuses the first name
            // entered -- which is every name.
            const session = ['(import (rnrs))']
                .concat(defs)
                .concat([printLast(input)])
                .join('\n');
            const bytes = await compileSource(session);
            const { text } = await runModule(bytes, []);
            // runModule has already decoded the program's bytes as
            // utf-8, so `text` is a string of characters and not a
            // string of bytes.  Re-encoding it as latin1 was writing
            // one byte per character, which is lossless only while
            // every character is below U+0100; anything else -- an
            // accent, a CJK character, an arrow the program printed --
            // arrived at the terminal as something other than what was
            // written.
            if (text)
                process.stdout.write(text.endsWith('\n') ? text : text + '\n');
            // successful evaluations contribute their definitions
            for (const [s, e] of topSpans(input)) {
                const form = input.slice(s, e);
                if (DEFINITION.test(form)) defs.push(form);
            }
        } catch (e) {
            if (e.output) process.stderr.write(e.output);
            console.error(e.message);
        }
    }

    async function onLine(line) {
        buf += (buf ? '\n' : '') + line;
        const d = balance(buf);
        if (d > 0) { prompt(); return; }
        const input = buf;
        buf = '';
        if (d < 0) {
            console.error('unbalanced parentheses; input dropped');
        } else if (input.trim()) {
            await evaluate(input);
        }
        prompt();
    }

    rl.on('line', (line) => {
        queue.push(line);
        if (busy) return;
        busy = true;
        (async () => {
            while (queue.length) await onLine(queue.shift());
            busy = false;
        })();
    });
    rl.on('close', () => {
        const drain = setInterval(() => {
            if (!busy && queue.length === 0) {
                clearInterval(drain);
                if (process.stdin.isTTY) console.log('');
                process.exit(0);
            }
        }, 10);
    });
    prompt();
}
