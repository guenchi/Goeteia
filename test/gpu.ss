;; expect: #t
;; (web gpu) against a recording mock: the adapter/device handshake
;; resolves through synchronous thenables (real promises in a real
;; browser), resources land in the slot table, and one replay turns
;; the staged words into render-pass calls and a single submit.
(import (rnrs) (web js) (web gpu))

(js-eval "
globalThis.__gpulog = [];
(() => {
  const log = globalThis.__gpulog;
  const push = (...a) => log.push(a.join(':'));
  const queue = {
    writeBuffer(buf, off, ab, base, bytes) {
      const fs = new Float32Array(ab, base, bytes / 4);
      push('writeBuffer', buf.id, bytes,
           fs[0].toFixed(2), fs[1].toFixed(2));
    },
    submit(l){ push('submit', l.length) } };
  const device = {
    queue,
    createShaderModule(d){ push('module', d.code.length); return {} },
    createRenderPipeline(d){
      push('pipeline', d.vertex.buffers[0].arrayStride,
           d.vertex.buffers[0].attributes
             .map(a => a.format + '@' + a.offset + '>' + a.shaderLocation)
             .join('|'),
           d.fragment.targets[0].format);
      return { id: 'PL' + (this._p = (this._p || 0) + 1) } },
    createBuffer(d){
      push('buffer', d.size);
      return { id: 'B' + (this._b = (this._b || 0) + 1) } },
    createCommandEncoder(){
      return {
        beginRenderPass(d){
          const c = d.colorAttachments[0];
          push('beginPass', c.loadOp,
               c.clearValue.r.toFixed(2), c.clearValue.g.toFixed(2),
               c.clearValue.b.toFixed(2), c.clearValue.a.toFixed(2));
          return { setPipeline(p){ push('setPipeline', p.id) },
                   setVertexBuffer(i, b){ push('setVbuf', i, b.id) },
                   draw(n){ push('draw', n) },
                   end(){ push('endPass') } } },
        finish(){ return {} } } } };
  const adapter = {
    requestDevice(){ return { then(f){ return f(device) } } } };
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { gpu: {
      requestAdapter(){ return { then(f){ return f(adapter) } } },
      getPreferredCanvasFormat(){ return 'bgra8unorm' } } } });
  globalThis.__mockcanvas = {
    getContext(kind) {
      push('getContext', kind);
      return { configure(d){ push('configure', d.format, d.alphaMode) },
               getCurrentTexture(){ return { createView(){ return {} } } } } } };
})()")

(define log (js-get (js-global) "__gpulog"))
(define (entry i) (js->string (js-index log i)))
(define (check i exp)
  (or (string=? (entry i) exp)
      (begin (display "mismatch at ") (display i) (display ": got ")
             (display (entry i)) (display " want ") (display exp) (newline)
             #f)))

;; the handshake calls back (synchronously, through the mock's
;; thenables) with the canvas configured
(define ready #f)
(gpu-attach! (js-get (js-global) "__mockcanvas") (lambda () (set! ready #t)))

(define attach-ok
  (and ready
       (check 0 "getContext:webgpu")
       (check 1 "configure:bgra8unorm:opaque")))

;; resources: a pipeline over one interleaved buffer, and the buffer
(gpu-pipeline! 0 "@vertex fn vs() {} @fragment fn fs() {}"
               24 "float32x2,float32x4")
(gpu-buffer! 1 144)
(define resource-ok
  (and (check 2 "module:39")
       (check 3 "pipeline:24:float32x2@0>0|float32x4@8>1:bgra8unorm")
       (check 4 "buffer:144")))

;; one frame: staged floats reach writeBuffer, the pass opens with
;; the frame's clear color at the draw, one submit closes it
(%mem-f32-set! 4096 0.25)
(%mem-f32-set! 4100 -1.5)
(gpu-begin!)
(gpu-clear! 0.02 0.03 0.05 1.0)
(gpu-use-pipeline! 0)
(gpu-bind-vbuf! 1)
(gpu-buffer-data! 1 4096 144)
(gpu-draw! 6)
(gpu-flush!)
(define frame-ok
  (and (check 5 "writeBuffer:B1:144:0.25:-1.50")
       (check 6 "beginPass:clear:0.02:0.03:0.05:1.00")
       (check 7 "setPipeline:PL1")
       (check 8 "setVbuf:0:B1")
       (check 9 "draw:6")
       (check 10 "endPass")
       (check 11 "submit:1")))

;; a clear-only frame still opens (and clears) the pass
(gpu-begin!)
(gpu-clear! 1.0 0.0 0.0 1.0)
(gpu-flush!)
(define clear-ok
  (and (check 12 "beginPass:clear:1.00:0.00:0.00:1.00")
       (check 13 "endPass")
       (check 14 "submit:1")))

(and attach-ok resource-ok frame-ok clear-ok)
