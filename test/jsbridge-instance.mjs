import assert from 'node:assert/strict';
import test from 'node:test';
import { makeJsBridge } from '../rt/jsbridge.mjs';

test('Goeteia globals and memory stay with their module instance', () => {
    const memoryA = new WebAssembly.Memory({ initial: 1 });
    const memoryB = new WebAssembly.Memory({ initial: 1 });
    const bridgeA = makeJsBridge(() => ({ memory: memoryA }));
    const bridgeB = makeJsBridge(() => ({ memory: memoryB }));
    const globalA = bridgeA.global();
    const globalB = bridgeB.global();

    globalA.eval('globalThis.__goeteia_helper = () => globalThis.__goeteia_mem');
    globalB.eval('globalThis.__goeteia_helper = () => globalThis.__goeteia_mem');

    assert.equal(globalA.__goeteia_helper(), memoryA);
    assert.equal(globalB.__goeteia_helper(), memoryB);
    assert.equal(globalThis.__goeteia_helper, undefined);
});
