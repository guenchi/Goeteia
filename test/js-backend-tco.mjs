// Deep NON-self tail recursion must run in constant stack on both
// targets: wasm has return_call, the JS target has the trampoline.
// Closures through a vector defeat the inliner, so these really are
// cross-function tail calls.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-tco-'));

try {
    const source =
        '(define fns (vector #f #f))\n' +
        '(vector-set! fns 0 (lambda (n) (if (= n 0) #t ((vector-ref fns 1) (- n 1)))))\n' +
        '(vector-set! fns 1 (lambda (n) (if (= n 0) #f ((vector-ref fns 0) (- n 1)))))\n' +
        '((vector-ref fns 0) 1000000)\n';
    const sourceFile = path.join(dir, 'deep.ss');
    const jsFile = path.join(dir, 'deep.mjs');
    fs.writeFileSync(sourceFile, source, 'utf8');
    const wasm = await compileToBytes(sourceFile, { script: true });
    fs.writeFileSync(
        jsFile,
        await compileToBytes(sourceFile, { script: true, target: 'js' }));
    assert.equal((await runModule(wasm)).result, '#t', 'wasm');
    assert.equal((await runJsModule(jsFile)).result, '#t', 'js');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
