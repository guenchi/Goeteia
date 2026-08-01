// Host-visible export names must preserve the UTF-8 spelling used by Wasm.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { compileToBytes } from '../rt/compile.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-exports-'));

try {
    const exportName = '\u03bb';
    const sourceFile = path.join(dir, 'unicode-export.ss');
    const jsFile = path.join(dir, 'unicode-export.mjs');
    fs.writeFileSync(
        sourceFile,
        `(export ${exportName})\n` +
        `(define (${exportName} x) x)\n` +
        `(${exportName} 1)\n`,
        'utf8');

    const wasm = await compileToBytes(sourceFile, { script: true });
    fs.writeFileSync(
        jsFile,
        await compileToBytes(sourceFile, { script: true, target: 'js' }));

    const wasmNames = WebAssembly.Module.exports(
        new WebAssembly.Module(wasm)).map(entry => entry.name);
    assert.ok(wasmNames.includes(exportName));
    const js = await import(pathToFileURL(jsFile).href);
    assert.deepEqual(Object.keys(js.xports), [exportName]);
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
