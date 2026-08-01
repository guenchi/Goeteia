// Wasm i32.trunc_f64_s rejects non-finite and out-of-i32 values.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-fl-conversion-'));

async function compile(name, source) {
    const sourceFile = path.join(dir, `${name}.ss`);
    const jsFile = path.join(dir, `${name}.mjs`);
    fs.writeFileSync(sourceFile, source, 'utf8');
    const wasm = await compileToBytes(sourceFile, { script: true });
    fs.writeFileSync(
        jsFile,
        await compileToBytes(sourceFile, { script: true, target: 'js' }));
    return { wasm, jsFile };
}

async function bothReject(name, source) {
    const { wasm, jsFile } = await compile(name, source);
    await assert.rejects(() => runModule(wasm), undefined, `${name}: wasm`);
    await assert.rejects(() => runJsModule(jsFile), undefined, `${name}: js`);
}

async function bothReturn(name, source, expected) {
    const { wasm, jsFile } = await compile(name, source);
    assert.equal((await runModule(wasm)).result, expected, `${name}: wasm`);
    assert.equal((await runJsModule(jsFile)).result, expected, `${name}: js`);
}

try {
    await bothReject('nan', '(%fl->fx (fl/ 0.0 0.0))\n');
    await bothReject('positive-infinity', '(%fl->fx (fl/ 1.0 0.0))\n');
    await bothReject('negative-infinity', '(%fl->fx (fl/ -1.0 0.0))\n');
    await bothReject('positive-overflow', '(%fl->fx 2147483648.0)\n');
    await bothReject('negative-overflow', '(%fl->fx -2147483649.0)\n');
    await bothReturn('positive-limit', '(%fl->fx 2147483647.0)\n', '-1');
    await bothReturn('negative-limit', '(%fl->fx -2147483648.0)\n', '0');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
