// Division failures cannot be represented by the one-value Scheme oracle.
// Both targets must reject division by zero instead of returning a value.
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


const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-division-'));

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
    await bothReject('quotient-zero', '(quotient 1 0)\n');
    await bothReject('remainder-zero', '(remainder 1 0)\n');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
