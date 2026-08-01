// Bounds failures cannot be represented by the one-value Scheme oracle.
// Both targets must reject invalid collection reads and writes.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-bounds-'));

async function bothReject(name, expression) {
    const sourceFile = path.join(dir, `${name}.ss`);
    const jsFile = path.join(dir, `${name}.mjs`);
    fs.writeFileSync(sourceFile, `(import (rnrs))\n${expression}\n`, 'utf8');
    const wasm = await compileToBytes(sourceFile, { script: true });
    fs.writeFileSync(
        jsFile,
        await compileToBytes(sourceFile, { script: true, target: 'js' }));
    await assert.rejects(() => runModule(wasm), undefined, `${name}: wasm`);
    await assert.rejects(() => runJsModule(jsFile), undefined, `${name}: js`);
}

try {
    await bothReject('string-ref', '(string-ref "a" 1)');
    await bothReject(
        'string-set',
        '(let ((s (make-string 1 #\\a))) (string-set! s 1 #\\b))');
    await bothReject('vector-ref', '(vector-ref (vector 1) 1)');
    await bothReject(
        'vector-set',
        '(let ((v (vector 1))) (vector-set! v 1 2))');
    await bothReject(
        'bytevector-ref',
        '(bytevector-u8-ref (make-bytevector 1) 1)');
    await bothReject(
        'bytevector-set',
        '(let ((v (make-bytevector 1))) (bytevector-u8-set! v 1 2))');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
