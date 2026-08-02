// Wasm collection operations ref.cast their heap operands before use.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-collection-types-'));

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
    await bothReject('string-length', '(string-length #f)\n');
    await bothReject('string-ref', '(string-ref #f 0)\n');
    await bothReject('string-set', '(string-set! #f 0 #\\a)\n');
    await bothReject('symbol-to-string', '(symbol->string #f)\n');
    await bothReject('make-symbol', '(%make-symbol #f)\n');
    await bothReject('vector-length', '(vector-length #f)\n');
    await bothReject('vector-ref', '(vector-ref #f 0)\n');
    await bothReject('vector-set', '(vector-set! #f 0 1)\n');
    await bothReject('bytevector-length', '(bytevector-length #f)\n');
    await bothReject('bytevector-ref', '(bytevector-u8-ref #f 0)\n');
    await bothReject('bytevector-set', '(bytevector-u8-set! #f 0 1)\n');
    // %make-bignum is wasm-only: the js target rides native BigInt
    // and rejects the limb constructor at compile time
    {
        const sourceFile = path.join(dir, 'bignum-limbs.ss');
        fs.writeFileSync(sourceFile, '(%make-bignum 0 #f)\n', 'utf8');
        const wasm = await compileToBytes(sourceFile, { script: true });
        await assert.rejects(() => runModule(wasm), undefined, 'bignum-limbs: wasm');
        await assert.rejects(
            () => compileToBytes(sourceFile, { script: true, target: 'js' }),
            undefined, 'bignum-limbs: js compile');
    }
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
