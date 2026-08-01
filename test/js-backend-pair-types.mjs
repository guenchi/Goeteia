// Wasm pair operations ref.cast their operands; JS property access must agree.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-pair-types-'));

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
    await bothReject('car', '(car #f)\n');
    await bothReject('cdr', '(cdr 1)\n');
    await bothReject('set-car', '(set-car! #t 1)\n');
    await bothReject('set-cdr', "(set-cdr! '() 1)\n");
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
