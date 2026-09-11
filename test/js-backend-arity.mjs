// Dynamic arity failures cannot be represented by the one-value Scheme
// oracle. Both targets must reject calls missing required arguments.
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


const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'goeteia-js-arity-'));

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

async function bothRejectOptimized(name, source) {
    const sourceFile = path.join(dir, `${name}.ss`);
    const jsFile = path.join(dir, `${name}.mjs`);
    fs.writeFileSync(sourceFile, withClause(source), 'utf8');
    const wasm = await compileToBytes(sourceFile);
    fs.writeFileSync(jsFile, await compileToBytes(sourceFile, { target: 'js' }));
    await assert.rejects(() => runModule(wasm), undefined, `${name}: wasm`);
    await assert.rejects(() => runJsModule(jsFile), undefined, `${name}: js`);
}

try {
    await bothReject(
        'fixed-arity',
        '(define h (vector (lambda (x) 42)))\n((vector-ref h 0))\n');
    await bothReject(
        'variadic-arity',
        '(define h (vector (lambda (x . rest) 42)))\n((vector-ref h 0))\n');
    await bothReject('apply-arity', "(apply (lambda (x) 42) '())\n");
    await bothReject(
        'callcc-arity',
        '(call/cc (lambda (k missing) 42))\n');
    await bothRejectOptimized(
        'unused-invalid-string',
        '(define unused (string #f))\n(display 42)\n');
    {
        const sourceFile = path.join(dir, 'unused-unbound.ss');
        fs.writeFileSync(sourceFile, withClause('(define unused missing)\n42\n'), 'utf8');
        await assert.rejects(
            () => compileToBytes(sourceFile, { script: true }),
            undefined, 'unused unbound initializer: wasm compile');
        await assert.rejects(
            () => compileToBytes(sourceFile, { script: true, target: 'js' }),
            undefined, 'unused unbound initializer: js compile');
    }
} finally {
    fs.rmSync(dir, { recursive: true, force: true });
}
