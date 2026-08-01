// Wasm flonum operations ref.cast their operands; JS must reject non-Fl values.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-flonum-types-'));

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
    await bothReject('add', '(fl+ 1.0 1)\n');
    await bothReject('subtract', '(fl- 1 1.0)\n');
    await bothReject('multiply', '(fl* 1.0 #f)\n');
    await bothReject('divide', '(fl/ #f 1.0)\n');
    await bothReject('equal', '(fl=? 1.0 1)\n');
    await bothReject('less', '(fl<? 1 1.0)\n');
    await bothReject('sqrt', '(flsqrt 1)\n');
    await bothReject('floor', '(flfloor #f)\n');
    await bothReject('truncate', '(fltruncate 1)\n');
    await bothReject('memory-f32', '(%mem-f32-set! 0 1)\n');
    await bothReject('memory-f64', '(%mem-f64-set! 0 #f)\n');
    await bothReject('simd-scale', '(%f32x4-scale! 0 0 1)\n');
    await bothReject('simd-axpy', '(%f32x4-axpy! 0 0 0 #f)\n');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
