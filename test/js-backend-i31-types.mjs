// Wasm ref.cast rejects non-i31 operands before integer unboxing.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runModule } from '../rt/run.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-i31-types-'));

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
    await bothReject('fixnum-to-flonum', '(fixnum->flonum #f)\n');
    await bothReject('char-to-integer', '(char->integer #f)\n');
    await bothReject('integer-to-char', '(integer->char #f)\n');
    await bothReject('bitwise', '(bitwise-and #f 1)\n');
    await bothReject('shift', '(bitwise-arithmetic-shift-left 1 #f)\n');
    await bothReject('make-string', '(%make-string #f)\n');
    await bothReject('make-vector', '(%make-vector #f 1)\n');
    await bothReject('make-bytevector', '(%make-bytevector 1 #f)\n');
    await bothReject('string-index', '(string-ref "a" #f)\n');
    await bothReject('bytevector-value',
                     '(bytevector-u8-set! (make-bytevector 1) 0 #f)\n');
    await bothReject('io-byte', '(%write-byte #f)\n');
    await bothReject('memory-address', '(%mem-u8-ref #f)\n');
    await bothReject('memory-value', '(%mem-u8-set! 0 #f)\n');
    await bothReject('memory-grow', '(%mem-grow #f)\n');
    await bothReject('simd-address', '(%f32x4-add! #f 0 0)\n');
    await bothReject('js-name-byte', '(%js-arg-byte #f)\n');
    await bothReject('js-string-index', '(%js-str-byte #f)\n');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
