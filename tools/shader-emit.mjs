// Copyright 2026 guenchi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


// Run tools/shader-emit.ss and parse what it prints.
//
// This lives here, and not beside the one test that used to hold it,
// because a second consumer arrived: one check compiles these shaders
// with a real GLSL compiler and needs a browser, and another asks a
// question about the same text that needs no browser at all.  Copying
// the twenty lines would have been the cheaper edit and would have
// created the shape this tree keeps removing -- two copies of one
// recipe, drifting apart with nothing to say which is right.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;

export function emitAll() {
    const dir = mkdtempSync(join(tmpdir(), 'goeteia-shaders-'));
    try {
        const wasm = join(dir, 'emit.wasm');
        execFileSync(join(root, 'bin/goeteiac'),
                     [join(root, 'tools/shader-emit.ss'), wasm], { cwd: root });
        const out = execFileSync('node', [join(root, 'rt/run.mjs'), wasm],
                                 { cwd: root, encoding: 'utf8', maxBuffer: 64 << 20 });
        const entries = [];
        let cur = null, part = null;
        for (const line of out.split('\n')) {
            const h = line.match(/^=== (\S+) (es\d+)$/);
            if (h) { cur = { name: h[1], dialect: h[2], vs: [], fs: [] }; entries.push(cur); part = null; continue; }
            if (line === '--- vertex ---') { part = 'vs'; continue; }
            if (line === '--- fragment ---') { part = 'fs'; continue; }
            if (cur && part) cur[part].push(line);
        }
        return entries.map(e => ({
            name: e.name, dialect: e.dialect,
            vs: e.vs.join('\n').trim(), fs: e.fs.join('\n').trim(),
        }));
    } finally { rmSync(dir, { recursive: true, force: true }); }
}
