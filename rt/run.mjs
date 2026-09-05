// goeteia host runner: instantiate a compiled module, call main,
// print whatever the program wrote followed by its decoded result.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'fs';
import path from 'path';
import { pathToFileURL } from 'url';
import { makeJsBridge, callMain } from './jsbridge.mjs';

// `args` is the program's own argv, which (web args) reads back at
// __goeteia_argv.  The bridge resolves __goeteia_* per instance, but
// only for names published THROUGH the instance proxy: the proxy's
// set trap is what files a name under this instance.  A write to the
// real globalThis lands in one process-wide slot instead, and two
// modules started together in one process then share it -- the one
// started first reads the other's arguments, which sequential starts
// never show.  So the bridge is built before anything is published
// and the list goes in through js.global().  Still no new wasm
// import, and a module that never imports (web args) is unaffected.
export async function runModule(bytes, input = [], args = []) {
    let exportsRef = null;
    const js = makeJsBridge(() => exportsRef);
    js.global().__goeteia_argv = args.map(String);
    const out = [];
    let pos = 0;

    // file ports: path pushed byte by byte, then opened
    let pathBuf = [];
    const files = new Map();
    let nextFd = 1;
    const fileIO = {
        path_byte: b => pathBuf.push(b),
        open_read: () => {
            const p = Buffer.from(pathBuf).toString(); pathBuf = [];
            try {
                const data = fs.readFileSync(p);
                const fd = nextFd++;
                files.set(fd, { data, pos: 0 });
                return fd;
            } catch { return -1; }
        },
        open_write: () => {
            const p = Buffer.from(pathBuf).toString(); pathBuf = [];
            const fd = nextFd++;
            files.set(fd, { path: p, out: [] });
            return fd;
        },
        fread: fd => {
            const f = files.get(fd);
            return f && f.pos < f.data.length ? f.data[f.pos++] : -1;
        },
        fwrite: (fd, b) => { files.get(fd).out.push(b); },
        fclose: fd => {
            const f = files.get(fd);
            if (f && f.out) fs.writeFileSync(f.path, Buffer.from(f.out));
            files.delete(fd);
        },
    };

    const { instance } = await WebAssembly.instantiate(bytes, {
        io: {
            write_byte: b => out.push(b),
            read_byte: () => (pos < input.length ? input[pos++] : -1),
            ...fileIO,
        },
        js,
    });
    exportsRef = instance.exports;
    const ex = instance.exports;
    const result = decode(await callMain(ex), ex);
    // drain microtasks so promise callbacks into wasm (fetch .then
    // chains from (web rpc)) run before we report the output
    await new Promise(r => setImmediate(r));
    return { text: Buffer.from(out).toString('utf8'), result };
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

if (process.argv[1] &&
    import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    // everything after a bare `--` is the program's argv, not ours;
    // an invocation without one is exactly what it was before
    const cut = process.argv.indexOf('--');
    const mine = cut < 0 ? process.argv : process.argv.slice(0, cut);
    const theirs = cut < 0 ? [] : process.argv.slice(cut + 1);
    const file = mine[2];
    if (!file) {
        console.error(
            'usage: node run.mjs <module.wasm> [input-file] [-- args...]');
        process.exit(1);
    }
    const input = mine[3] ? fs.readFileSync(mine[3]) : [];
    runModule(fs.readFileSync(file), input, theirs)
        .then(({ text, result }) => {
            if (text) process.stdout.write(text);
            if (text && !text.endsWith('\n') && result) process.stdout.write('\n');
            if (result) console.log(result);
            if (text && !result && !text.endsWith('\n')) process.stdout.write('\n');
        })
        .catch(e => { console.error(e.message); process.exit(1); });
}
