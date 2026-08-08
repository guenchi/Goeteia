// goeteia JS-target runner: import an emitted ES module, call main
// with the same io hooks run.mjs gives the wasm target, print the
// output and the decoded result.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.

import fs from 'fs';
import path from 'path';
import { pathToFileURL } from 'url';

// `args` is published the way run.mjs publishes it: the JS target's
// instance global resolves __goeteia_* through its own map and falls
// through to the real global, so (web args) reads the same list from
// either target.
export async function runJsModule(file, input = [], args = []) {
    globalThis.__goeteia_argv = args.map(String);
    const m = await import(pathToFileURL(path.resolve(file)).href);
    const out = [];
    let pos = 0;

    let pathBuf = [];
    const files = new Map();
    let nextFd = 1;
    const io = {
        write_byte: b => out.push(b),
        read_byte: () => (pos < input.length ? input[pos++] : -1),
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

    const result = decode(m.main(io), m.rt);
    // drain microtasks, mirroring the wasm runner
    await new Promise(r => setImmediate(r));
    return { text: Buffer.from(out).toString('utf8'), result };
}

export function decode(v, rt) {
    if (typeof v === 'number') {
        return (v & 1) ? `#\\${String.fromCharCode(v >> 1)}` : String(v >> 1);
    }
    if (v === rt.false) return '#f';
    if (v === rt.true) return '#t';
    if (v === rt.null) return '()';
    if (v === rt.void) return '';
    return '#<object>';
}

if (process.argv[1] &&
    import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    const cut = process.argv.indexOf('--');
    const mine = cut < 0 ? process.argv : process.argv.slice(0, cut);
    const theirs = cut < 0 ? [] : process.argv.slice(cut + 1);
    const file = mine[2];
    if (!file) {
        console.error(
            'usage: node runjs.mjs <module.js> [input-file] [-- args...]');
        process.exit(1);
    }
    const input = mine[3] ? fs.readFileSync(mine[3]) : [];
    runJsModule(file, input, theirs)
        .then(({ text, result }) => {
            if (text) process.stdout.write(text);
            if (text && !text.endsWith('\n') && result) process.stdout.write('\n');
            if (result) console.log(result);
            if (text && !result && !text.endsWith('\n')) process.stdout.write('\n');
        })
        .catch(e => { console.error(e.message); process.exit(1); });
}
