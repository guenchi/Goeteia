// Uint8Array silently accepts invalid indices; Wasm byte accesses trap.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-memory-bounds-'));

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
    await bothReject('read-negative', '(%mem-u8-ref -1)\n');
    await bothReject('read-past-end', '(%mem-u8-ref 65536)\n');
    await bothReject('write-negative', '(%mem-u8-set! -1 7)\n');
    await bothReject('write-past-end', '(%mem-u8-set! 65536 7)\n');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
