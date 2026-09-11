// Programs the import rule must NOT refuse, each a reviewer's fixture
// or a twin of a refusal: the check runs after expansion, where `and`
// has become `if` and `letrec` has become `begin` and `set!`, so core
// syntax the expander produces is not judged as a program reference;
// a record type needs cons and gets it through a compiler-introduced
// head even when the program excludes cons; a name the clause brings
// in is bound; a primitive no library exports is always bound; a
// renamed import is reachable under its new name.  The one refusal at
// the end is the twin that keeps the prelude exemption honest: it
// covers the prelude's internals only, so excluding a prelude
// procedure such as map and then calling it is unbound.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const chez = (() => { try { execFileSync('chez', ['--version'], { stdio: 'ignore' }); return 'chez'; } catch { return null; } })();

function run(src) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-legal-'));
    const ss = path.join(dir, 'p.ss');
    const wasm = path.join(dir, 'p.wasm');
    fs.writeFileSync(ss, src + '\n');
    const c = spawnSync(path.join(root, 'bin/goeteiac'), [ss, wasm], { encoding: 'utf8', timeout: 120000 });
    if (!fs.existsSync(wasm)) { fs.rmSync(dir, { recursive: true, force: true }); return { refused: ((c.stdout || '') + (c.stderr || '')).trim().split('\n').filter(l => !l.startsWith('at ')).pop() }; }
    const r = spawnSync('node', [path.join(root, 'rt/run.mjs'), wasm], { encoding: 'utf8', timeout: 20000 });
    fs.rmSync(dir, { recursive: true, force: true });
    return { out: ((r.stdout || '') + (r.stderr || '')).trim().split('\n')[0] };
}

const legal = [
    ['and under only',                  '(import (only (rnrs) and display))\n(display (and #t #t))',                       '#t'],
    ['letrec under only',               '(import (only (rnrs) letrec display))\n(display (letrec ((x 1)) x))',              '1'],
    ['a record type with cons excluded', '(import (except (rnrs) cons))\n(define-record-type pebble (fields))\n(display (if (pebble? (make-pebble)) 1 0))', '1'],
    ['a name the only list brings in',  '(import (only (rnrs) display))\n(display 1)',                                       '1'],
    ['an implementation primitive',     '(import (rnrs))\n(display (if (> (%mem-size) 0) 1 0))',                             '1'],
    ['a renamed import',                '(import (rename (rnrs) (display show)))\n(show 7)',                                 '7'],
];

for (const [title, src, want] of legal) {
    test(`legal: ${title}`, () => {
        if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
        const r = run(src);
        assert.ok(!('refused' in r), `refused: ${r.refused}`);
        assert.equal(r.out, want);
    });
}

test('twin: excluding a prelude procedure and calling it is unbound', () => {
    if (!chez) { console.log('NOT EXERCISED HERE (no chez on PATH; bin/goeteiac is Chez-hosted and this reading was NOT taken)'); return; }
    const r = run('(import (except (rnrs) map))\n(display (map (lambda (x) x) (list 1)))');
    assert.ok('refused' in r, `compiled and printed ${r.out}; the prelude exemption leaked map`);
    assert.match(r.refused, /unbound variable: map/);
});
