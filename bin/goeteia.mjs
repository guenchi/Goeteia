#!/usr/bin/env node
// Goeteia command-line driver.
//
//   goeteia compile <input.ss> [output.wasm]   compile to a wasm module
//   goeteia run <module.wasm> [input-file]      run a compiled module
//   goeteia <input.ss> [input-file]             compile and run in one step
//
// The self-hosted compiler (goeteia.wasm) and the prelude ship inside
// this package, so no external toolchain is required — just Node 22+.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'fs';
import path from 'path';
import { compileToBytes, compileFile } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { startDevServer } from '../rt/dev.mjs';

function usage(code = 0) {
    process.stdout.write(`Goeteia — a self-hosting Scheme for WebAssembly GC.

Usage:
  goeteia compile <input.ss> [output.wasm]   compile to a wasm module
  goeteia run <module.wasm> [input-file]      run a compiled module
  goeteia <input.ss> [input-file]             compile and run in one step
  goeteia repl                                interactive session
  goeteia dev [port]                          live-reload dev server (cwd)
  goeteia --version                           print the version
  goeteia --help                              show this message
`);
    process.exit(code);
}

function printResult({ text, result }) {
    if (text) process.stdout.write(text);
    if (text && !text.endsWith('\n') && result) process.stdout.write('\n');
    if (result) console.log(result);
    if (text && !result && !text.endsWith('\n')) process.stdout.write('\n');
}

async function main() {
    const argv = process.argv.slice(2);
    const cmd = argv[0];

    if (!cmd || cmd === '-h' || cmd === '--help') usage(0);
    if (cmd === '-v' || cmd === '--version') {
        const pkg = JSON.parse(fs.readFileSync(
            new URL('../package.json', import.meta.url)));
        console.log(pkg.version);
        return;
    }

    try {
        if (cmd === 'compile') {
            const src = argv[1];
            if (!src) usage(1);
            const out = argv[2] || src.replace(/\.\w+$/, '') + '.wasm';
            await compileFile(src, out);
            console.error(`wrote ${out}`);
            return;
        }

        if (cmd === 'dev') {
            startDevServer({ port: Number(argv[1]) || 8100 });
            return;
        }

        if (cmd === 'repl') {
            const { startRepl } = await import('../rt/repl.mjs');
            await startRepl();
            return;
        }

        if (cmd === 'run') {
            const file = argv[1];
            if (!file) usage(1);
            const input = argv[2] ? fs.readFileSync(argv[2]) : [];
            printResult(await runModule(fs.readFileSync(file), input));
            return;
        }

        // bare source file: compile in memory, then run
        if (/\.(ss|scm|sc|sls)$/.test(cmd)) {
            if (!fs.existsSync(cmd)) throw new Error(`no such file: ${cmd}`);
            const bytes = await compileToBytes(cmd);
            const input = argv[1] ? fs.readFileSync(argv[1]) : [];
            printResult(await runModule(bytes, input));
            return;
        }

        console.error(`goeteia: unknown command '${cmd}'\n`);
        usage(1);
    } catch (e) {
        if (e.output) process.stderr.write(e.output);
        console.error(e.message);
        process.exit(1);
    }
}

main();
