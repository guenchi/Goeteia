// A primitive call whose head the lowering replaced with an intrinsic
// record must compile to the same code as the same call written with
// the bare symbol.  The lowering exists to fix WHICH binding a head
// names, not to change how the call is emitted; but every emission
// fast path that asks "is this head the primitive X" by looking at a
// symbol falls through to the generic path when it meets a record, and
// the generic path costs eight instructions per predicate test.
//
// The fixture writes one function twice: in a library, where the
// lowering rewrites its null? and cdr heads, and in the program, where
// it does not.  The two bodies are compared by instruction count
// through the walker, after the fixture has been shown to compile and
// to answer (3 3) -- the first version of this file did not compile at
// all and its red was a parse failure.  Measured with compiler
// 8d110202: library copy 88 instructions, program copy 80; with
// 4d60f6e9 (head-op at every emission fast path) both 80; with
// 6cc5d643 both 80 because that compiler lowers only car.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readModule } from './lib/wasm-walk.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

const SRC = `(import (rnrs))
(begin
  (library (o l)
    (export lib-len)
    (import (rnrs))
    (define (lib-len xs) (if (null? xs) 0 (+ 1 (lib-len (cdr xs))))))
  (import (o l)))
(define (prog-len xs) (if (null? xs) 0 (+ 1 (prog-len (cdr xs)))))
(display (list (lib-len (list 1 2 3)) (prog-len (list 1 2 3))))
`;

test('a lowered head compiles to the same code as the written one', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-ihead-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, SRC);
    const c = execFileSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    assert.ok(fs.existsSync(wasm), `the fixture did not compile:\n${c}`);
    const out = execFileSync('node', [path.join(root, 'rt/run.mjs'), wasm], { encoding: 'utf8' }).trim();
    assert.equal(out, '(3 3)', 'the fixture must run and agree with itself before its code is compared');
    const m = readModule(fs.readFileSync(wasm));
    fs.rmSync(dir, { recursive: true, force: true });
    const names = [...m.names.values()];
    const lib = names.find(n => n.endsWith('lib-len'));
    const prog = names.find(n => n.endsWith('prog-len'));
    assert.ok(lib && prog, `both functions must survive into the module; names: ${names.filter(n => /len/.test(n)).join(' ')}`);
    const a = m.inspect(lib), b = m.inspect(prog);
    assert.ok(a.clean && b.clean, 'both bodies must walk cleanly');
    assert.equal(a.ops, b.ops, `the library copy (heads lowered) emits ${a.ops} instructions, the program copy (heads written) ${b.ops}`);
});
