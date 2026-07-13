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
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import readline from 'readline';
import { compileSource } from './compile.mjs';
import { runModule } from './run.mjs';

// paren balance, aware of strings, comments and char literals
function balance(text) {
    let depth = 0;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (c === ';') { while (i < text.length && text[i] !== '\n') i++; continue; }
        if (c === '"') { i++; while (i < text.length && text[i] !== '"') { if (text[i] === '\\') i++; i++; } continue; }
        if (c === '#' && text[i + 1] === '\\') { i += 2; continue; }
        if (c === '(') depth++;
        else if (c === ')') depth--;
    }
    return depth;
}

// top-level form spans (same scanner shape as the balance check)
function topSpans(text) {
    const spans = [];
    let depth = 0, start = -1;
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (c === ';') { while (i < text.length && text[i] !== '\n') i++; continue; }
        if (c === '"') { i++; while (i < text.length && text[i] !== '"') { if (text[i] === '\\') i++; i++; } continue; }
        if (c === '#' && text[i + 1] === '\\') { i += 2; continue; }
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
        if (tail.trim())                 // a bare atom: lst, 42, ...
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
            const session = defs.concat([printLast(input)]).join('\n');
            const bytes = await compileSource(session);
            const { text } = await runModule(bytes, []);
            // write raw bytes: the program's output is already utf-8
            if (text)
                process.stdout.write(
                    Buffer.from(text.endsWith('\n') ? text : text + '\n',
                                'latin1'));
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
