// The JS target cannot suspend (js-await is the identity), so its
// JSPI probes must answer no even when the host engine has JSPI --
// otherwise (web fetch)'s feature test would pick the direct style
// and hang.  Both the eval and the js-get probe paths are shimmed.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compileToBytes } from '../rt/compile.mjs';
import { runJsModule } from '../rt/runjs.mjs';

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-jspi-'));

async function probe(name, source) {
    const sourceFile = path.join(dir, `${name}.ss`);
    const jsFile = path.join(dir, `${name}.mjs`);
    fs.writeFileSync(sourceFile, source, 'utf8');
    fs.writeFileSync(
        jsFile,
        await compileToBytes(sourceFile, { script: true, target: 'js' }));
    return (await runJsModule(jsFile)).text;
}

try {
    assert.equal(await probe('eval-probe',
        '(import (web js))\n' +
        '(display (if (js-truthy? (js-eval ' +
        '"typeof WebAssembly.Suspending === \'function\'")) 1 0))\n'),
        '0', 'eval probe must not see JSPI');
    assert.equal(await probe('get-probe',
        '(import (web js))\n' +
        '(display (if (js-truthy? (js-get (js-get (js-global) ' +
        '"WebAssembly") "Suspending")) 1 0))\n'),
        '0', 'js-get probe must not see JSPI');
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
