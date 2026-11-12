;; A WebGPU mock that LOGS EVERY CALL, for tests that compare two replays
;; of the (gfx gpu) command stream call for call, or check what an upload
;; read.
;;
;; It lives here because the cells about the WebGPU command region (R52:
;; test/gpu-full-region-leaves-whole-commands.ss,
;; test/sgpu-init-sets-the-command-region.ss) ask the same questions of
;; the same device.  test/sgpu.ss keeps its own recording mock, which
;; logs a chosen subset; this one logs everything, so nothing a replay
;; does can differ without the log differing.
;;
;; What it keeps:
;;   EVERY CALL, with its arguments: objects by name, numbers rounded to
;;     three places, typed arrays and ArrayBuffer ranges by length and an
;;     FNV-1a hash of their bytes -- on the device, the queue, every
;;     command encoder, render pass, compute pass and bundle encoder.
;;   WHAT AN UPLOAD READ: writeBuffer hashes the bytes of the range it is
;;     given at the moment it is called, which is the moment of the
;;     replay.
;;   STABLE NAMES PER FRAME: what a replay makes anew every time -- the
;;     command encoder, its passes, a bundle encoder, a texture view --
;;     has a fixed name, so two replays of the same words log the same
;;     lines; resources made once (buffers, pipelines, bind groups,
;;     textures, finished bundles) are numbered in creation order.
;;   ANY ARGUMENT SHAPE: a slot that was never made reaches the mock as
;;     undefined and is logged as such; nothing here dereferences an
;;     argument, so a replay of any word sequence runs to its end.
;;   A FAILURE ON DEMAND (R40g): gpustate-fail-write! arms the n-th
;;     queue.writeBuffer from now to throw instead of reading; it fires
;;     once and disarms.  The throw unwinds the replay and whatever
;;     called it, as a device error would; gpustate-attempt catches it.
;;   A WORD ON DEMAND (R40g): gpustate-watch-u32! bytes off makes every
;;     writeBuffer of that many bytes also log queue.u32(<value>), the
;;     little-endian u32 at offset off of what it read -- a value a cell
;;     must know, not only compare (an env block's occlusion mode).  Off
;;     until set; (gpustate-watch-u32! #f 0) turns it off.
;; The adapter offers no optional feature: the timer stays off.
(library (gpustate)
  (export gpustate-canvas gpustate-reset! gpustate-calls gpustate-attempt
          gpustate-fail-write! gpustate-watch-u32!)
  (import (rnrs) (web js))

  (define $src "globalThis.__gpustate = (() => {
  const st = { calls: [] };
  const fnv = (b) => { let h = 0x811c9dc5; for (let i = 0; i < b.length; i++) { h ^= b[i]; h = Math.imul(h, 0x01000193) >>> 0; } return h.toString(16); };
  const show = (a) => {
    if (a === null) return 'null';
    if (a === undefined) return 'undef';
    if (typeof a === 'number') return String(Math.round(a * 1000) / 1000);
    if (typeof a === 'string') return a;
    if (typeof a === 'boolean') return a ? 'T' : 'F';
    if (ArrayBuffer.isView(a)) return 'bytes' + a.byteLength + '#' + fnv(new Uint8Array(a.buffer, a.byteOffset, a.byteLength));
    if (a instanceof ArrayBuffer) return 'ab';
    if (Array.isArray(a)) return '[' + a.map(show).join(',') + ']';
    if (a && a.tag) return a.tag;
    if (a && typeof a === 'object') return '{' + Object.keys(a).sort().map(k => k + '=' + show(a[k])).join(';') + '}';
    return 'fn'; };
  const rec = (name, args) => { st.calls.push(name + '(' + args.map(show).join(',') + ')'); };
  let n = 0;
  const tag = (p) => p + (++n);
  const logged = (name, specials) => new Proxy(specials || {}, { get(t, k) {
    if (typeof k !== 'string') return undefined;
    if (k === 'tag') return name;
    if (k in t) return (...a) => { rec(name + '.' + k, a); return t[k](...a); };
    return (...a) => { rec(name + '.' + k, a); return undefined; }; } });
  const view = () => ({ tag: 'V' });
  const queue = logged('queue', {
    writeBuffer(buf, off, ab, base, bytes) {
      if (st.failIn > 0 && --st.failIn === 0) {
        st.calls.push('queue.FAILED(' + bytes + ')');
        throw new Error('gpustate: injected writeBuffer failure'); }
      st.calls.push('queue.read(' + bytes + '#' + fnv(new Uint8Array(ab, base, bytes)) + ')');
      if (st.watchBytes === bytes)
        st.calls.push('queue.u32(' + new DataView(ab).getUint32(base + st.watchOff, true) + ')'); },
    submit() {} });
  const device = logged('dev', {
    createShaderModule() { return { tag: tag('M') }; },
    createTexture() { return { tag: tag('T'), createView: view }; },
    createBindGroup() { return { tag: tag('G') }; },
    createRenderPipeline() { const t = tag('RP'); return { tag: t, getBindGroupLayout: (i) => ({ tag: t + 'L' + i }) }; },
    createComputePipeline() { const t = tag('CP'); return { tag: t, getBindGroupLayout: (i) => ({ tag: t + 'L' + i }) }; },
    createBuffer(d) { return { tag: tag('B'), size: d && d.size }; },
    createSampler() { return { tag: tag('S') }; },
    createQuerySet() { return { tag: tag('Q') }; },
    createRenderBundleEncoder() {
      return logged('BE', { finish() { return { tag: tag('BN') }; } }); },
    createCommandEncoder() {
      return logged('E', {
        beginRenderPass() { return logged('RPass'); },
        beginComputePass() { return logged('CPass'); },
        finish() { return { tag: 'CB' }; } }); } });
  const raw = { queue,
    features: { has() { return false; } },
    limits: {} };
  const dev = new Proxy(raw, { get(t, k) { return k in t ? t[k] : device[k]; } });
  const adapter = { features: { has() { return false; } },
    requestDevice() { return { then(f) { return f(dev); } }; } };
  Object.defineProperty(globalThis, 'navigator', { configurable: true,
    value: { gpu: { requestAdapter() { return { then(f) { return f(adapter); } }; },
                    getPreferredCanvasFormat() { return 'bgra8unorm'; } } } });
  st.attempt = (fn) => { try { fn(); return 'ok'; } catch (e) { return 'raised:' + (e && e.name); } };
  st.failIn = 0;
  st.watchBytes = null; st.watchOff = 0;
  st.watch = (b, o) => { st.watchBytes = (b === false ? null : b); st.watchOff = o; };
  st.failWrite = (n) => { st.failIn = n; };
  st.reset = () => { st.calls = []; };
  st.make = (w, h) => ({ tag: 'canvas', width: w, height: h, addEventListener() {},
    getContext() { return { tag: 'ctx', configure() {}, getCurrentTexture() { return { tag: 'tex', createView: view }; } }; } });
  return st; })();")

  (define $st (begin (js-eval $src) (js-get (js-global) "__gpustate")))
  (define ($list arr conv)
    (let ((n (js->number (js-get arr "length"))))
      (let loop ((i (- n 1)) (out '()))
        (if (< i 0) out (loop (- i 1) (cons (conv (js-index arr i)) out))))))

  ;; a canvas whose WebGPU context and device are the mock
  (define (gpustate-canvas w h) (js-call (js-get $st "make") $st w h))
  ;; forget the logged calls; objects are kept
  (define (gpustate-reset!) (js-call (js-get $st "reset") $st))
  ;; every call since the last reset, with its arguments
  (define (gpustate-calls) ($list (js-get $st "calls") js->string))
  ;; run thunk under a JS try: "ok", or "raised:<error name>"
  ;; the n-th queue.writeBuffer from now throws (n = 1: the next one);
  ;; once, then disarmed.  It is logged as queue.FAILED(<bytes>)
  (define (gpustate-fail-write! n) (js-call (js-get $st "failWrite") $st n))
  ;; uploads of `bytes' bytes also log queue.u32(<the u32 at off>); #f: off
  (define (gpustate-watch-u32! bytes off) (js-call (js-get $st "watch") $st bytes off))
  (define (gpustate-attempt thunk)
    (js->string (js-call (js-get $st "attempt") $st thunk))))
