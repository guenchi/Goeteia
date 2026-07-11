// schwasm host runner: instantiate a compiled module, call main,
// print the decoded result.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'fs';

export async function runModule(bytes) {
    const { instance } = await WebAssembly.instantiate(bytes, {});
    const ex = instance.exports;
    return decode(ex.main(), ex);
}

export function decode(v, ex) {
    // i31ref surfaces in JS as a number
    if (typeof v === 'number') return String(v);
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
        .then(out => console.log(out))
        .catch(e => { console.error(e.message); process.exit(1); });
}
