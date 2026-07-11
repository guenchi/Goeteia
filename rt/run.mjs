// schwasm host runner: instantiate a compiled module, call main,
// print whatever the program wrote followed by its decoded result.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'fs';

export async function runModule(bytes) {
    const out = [];
    const { instance } = await WebAssembly.instantiate(bytes, {
        io: { write_byte: b => out.push(b) },
    });
    const ex = instance.exports;
    const result = decode(ex.main(), ex);
    return { text: Buffer.from(out).toString('latin1'), result };
}

export function decode(v, ex) {
    // i31ref surfaces in JS as a number; fixnums and characters share
    // it with a one-bit tag
    if (typeof v === 'number') {
        return (v & 1) ? `#\\${String.fromCharCode(v >> 1)}` : String(v >> 1);
    }
    if (v === ex.false.value) return '#f';
    if (v === ex.true.value) return '#t';
    if (v === ex.null.value) return '()';
    if (v === ex.void.value) return '';
    return '#<object>';
}

if (import.meta.url === `file://${process.argv[1]}`) {
    const file = process.argv[2];
    if (!file) {
        console.error('usage: node run.mjs <module.wasm>');
        process.exit(1);
    }
    runModule(fs.readFileSync(file))
        .then(({ text, result }) => {
            if (text) process.stdout.write(text);
            if (text && !text.endsWith('\n') && result) process.stdout.write('\n');
            if (result) console.log(result);
            if (text && !result && !text.endsWith('\n')) process.stdout.write('\n');
        })
        .catch(e => { console.error(e.message); process.exit(1); });
}
