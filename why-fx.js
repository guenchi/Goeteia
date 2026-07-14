// Load the precompiled why-fx.wasm (built by build.sh from
// why-fx.ss) and run it against the live DOM: the typeset-driven
// headings whose glyphs dodge the cursor.
// Copyright (c) 2026 guenchi. MIT license; see LICENSE.
import { makeJsBridge } from './rt/jsbridge.mjs';

const stubs = {
  write_byte: () => {}, read_byte: () => -1,
  path_byte: () => {}, open_read: () => -1, open_write: () => -1,
  fread: () => -1, fwrite: () => {}, fclose: () => {},
};

const bytes = await fetch('why-fx.wasm').then(r => {
  if (!r.ok) throw new Error('why-fx.wasm not found');
  return r.arrayBuffer();
});
let ex;
let instance;
try {
  ({ instance } = await WebAssembly.instantiate(bytes, {
    io: stubs, js: makeJsBridge(() => ex),
  }));
} catch (e) {
  // engine advertised WebAssembly.Suspending but rejected it as an
  // import; retry with a plain no-op await (same dance as live.js)
  const js = makeJsBridge(() => ex);
  js.await = p => p;
  ({ instance } = await WebAssembly.instantiate(bytes, { io: stubs, js }));
}
ex = instance.exports;
if (ex.memory) globalThis.__goeteia_mem = ex.memory;
ex.main();
