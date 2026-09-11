// Wasm pair operations ref.cast their operands; JS property access must agree.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

// A program begins with an import form.  These fixtures are the
// backend's own test programs and predate that rule, so the clause is
// added here rather than to each literal: one place, and a fixture
// that already carries one is left alone.
const withClause = (s) =>
    /^\s*\(import\b/m.test(s) ? s : '(import (rnrs))\n' + s;


const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-pair-types-'));

async function bothReject(name, source) {
    const sourceFile = path.join(dir, `${name}.ss`);
    const jsFile = path.join(dir, `${name}.mjs`);
    fs.writeFileSync(sourceFile, withClause(source), 'utf8');
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
