// Dynamic arity failures cannot be represented by the one-value Scheme
// oracle. Both targets must reject calls missing required arguments.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-arity-'));

async function bothReject(name, source) {
    const sourceFile = path.join(dir, `${name}.ss`);
    const jsFile = path.join(dir, `${name}.mjs`);
    fs.writeFileSync(sourceFile, source, 'utf8');
    const wasm = await compileToBytes(sourceFile, { script: true });
    fs.writeFileSync(
        jsFile,
        await compileToBytes(sourceFile, { script: true, target: 'js' }));
    await assert.rejects(() => runModule(wasm), undefined, `${name}: wasm`);
    await assert.rejects(() => runJsModule(jsFile), undefined, `${name}: js`);
}

try {
    await bothReject(
        'fixed-arity',
        '(define h (vector (lambda (x) 42)))\n((vector-ref h 0))\n');
    await bothReject(
        'variadic-arity',
        '(define h (vector (lambda (x . rest) 42)))\n((vector-ref h 0))\n');
    await bothReject('apply-arity', "(apply (lambda (x) 42) '())\n");
    await bothReject(
        'callcc-arity',
        '(call/cc (lambda (k missing) 42))\n');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
