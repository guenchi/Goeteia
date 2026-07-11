// Run the self-hosted schwasm compiler (a wasm module): feed it the
// prelude plus a source file, collect the wasm bytes it emits.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'fs';
import path from 'path';
import url from 'url';

const here = path.dirname(url.fileURLToPath(import.meta.url));

async function main() {
    const [compilerWasm, sourceFile, outFile] = process.argv.slice(2);
    if (!outFile) {
        console.error('usage: node compile.mjs <compiler.wasm> <input.ss> <output.wasm>');
        process.exit(1);
    }
    const prelude = fs.readFileSync(path.join(here, '../src/prelude.ss'));
    const source = fs.readFileSync(sourceFile);
    const input = Buffer.concat([prelude, Buffer.from('\n'), source]);

    const out = [];
    let pos = 0;
    const { instance } = await WebAssembly.instantiate(
        fs.readFileSync(compilerWasm),
        {
            io: {
                write_byte: b => out.push(b),
                read_byte: () => (pos < input.length ? input[pos++] : -1),
            },
        });
    try {
        instance.exports.main();
    } catch (e) {
        // compile errors print through the output channel before trapping
        process.stderr.write(Buffer.from(out).toString('latin1'));
        console.error(`\ncompile failed: ${e.message}`);
        process.exit(1);
    }
    fs.writeFileSync(outFile, Buffer.from(out));
}

main();
