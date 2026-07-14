;; expect: #t
;; (gfx gpu) against a recording mock: the adapter/device handshake
;; resolves through synchronous thenables (real promises in a real
;; browser), resources land in the slot table, and one replay turns
;; the staged words into render-pass calls and a single submit.
(import (rnrs) (web js) (gfx gpu))

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
    submit(l){ push('submit', l.length) },
    writeTexture(dst, data, lay, size) {
      push('writeTexture', dst.texture.id, data.length,
           lay.bytesPerRow, size.join('x')) } };
  const device = {
    queue,
    createShaderModule(d){ push('module', d.code.length); return {} },
    createTexture(d){
      push('texture', d.size.join('x'), d.format);
      const id = 'T' + (this._t = (this._t || 0) + 1);
      return { id, createView(){ return { id: id + 'v' } } } },
    createBindGroup(d){
      push('bindgroup', d.layout.id,
           d.entries.map(e => e.binding + '=' +
                         (e.resource.buffer ? e.resource.buffer.id
                                            : e.resource.id))
             .join('|'));
      return { id: 'G' + (this._g = (this._g || 0) + 1) } },
    createRenderPipeline(d){
      push('pipeline', d.vertex.buffers[0].arrayStride,
           d.vertex.buffers[0].attributes
             .map(a => a.format + '@' + a.offset + '>' + a.shaderLocation)
             .join('|'),
           d.fragment.targets[0].format);
      if (d.vertex.buffers[1])
        push('instance', d.vertex.buffers[1].arrayStride,
             d.vertex.buffers[1].attributes
               .map(a => a.format + '@' + a.offset + '>' + a.shaderLocation)
               .join('|'));
      push('depth', d.depthStencil.format, d.depthStencil.depthCompare);
      return { id: 'PL' + (this._p = (this._p || 0) + 1),
               getBindGroupLayout(i){ return { id: 'L' + i } } } },
    createBuffer(d){
      push('buffer', d.size, d.usage);
      return { id: 'B' + (this._b = (this._b || 0) + 1) } },
    createSampler(d){
      push('sampler', d.magFilter);
      return { id: 'S' + (this._s = (this._s || 0) + 1) } },
    createComputePipeline(d){
      push('computePipeline', d.compute.entryPoint);
      return { id: 'CP' + (this._c = (this._c || 0) + 1),
               getBindGroupLayout(i){ return { id: 'CL' + i } } } },
    createRenderBundleEncoder(d){
      push('bundleEnc', d.colorFormats.join(','), d.depthStencilFormat);
      return { setPipeline(p){ push('b.setPipeline', p.id) },
               setVertexBuffer(i, b){ push('b.setVbuf', i, b.id) },
               setBindGroup(i, g){ push('b.setGroup', i, g.id) },
               setIndexBuffer(b, f){ push('b.setIbuf', b.id, f) },
               draw(n, inst){ push('b.draw', inst === undefined ? n : n + ':' + inst) },
               drawIndexed(n){ push('b.drawIndexed', n) },
               finish(){ push('b.finish');
                         return { id: 'BN' + (this._n = (this._n || 0) + 1) } } } },
    createCommandEncoder(){
      return {
        beginRenderPass(d){
          const c = d.colorAttachments[0];
          push('beginPass', c.loadOp,
               c.clearValue.r.toFixed(2), c.clearValue.g.toFixed(2),
               c.clearValue.b.toFixed(2), c.clearValue.a.toFixed(2),
               d.depthStencilAttachment ? d.depthStencilAttachment.depthLoadOp : 'nodepth');
          return { setPipeline(p){ push('setPipeline', p.id) },
                   executeBundles(bs){ push('exec', bs[0].id) },
                   setVertexBuffer(i, b){ push('setVbuf', i, b.id) },
                   setBindGroup(i, g){ push('setGroup', i, g.id) },
                   setIndexBuffer(b, f){ push('setIbuf', b.id, f) },
                   draw(n, inst){ push('draw', inst === undefined ? n : n + ':' + inst) },
                   drawIndexed(n){ push('drawIndexed', n) },
                   drawIndexedIndirect(b, o){ push('drawIndexedIndirect', b.id, o) },
                   drawIndirect(b, o){ push('drawIndirect', b.id, o) },
                   end(){ push('endPass') } } },
        beginComputePass(){
          return { setPipeline(p){ push('csPipeline', p.id) },
                   setBindGroup(i, g){ push('csGroup', i, g.id) },
                   dispatchWorkgroups(n){ push('dispatch', n) },
                   end(){ push('csEnd') } } },
        finish(){ return {} } } } };
  const adapter = {
    requestDevice(){ return { then(f){ return f(device) } } } };
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { gpu: {
      requestAdapter(){ return { then(f){ return f(adapter) } } },
      getPreferredCanvasFormat(){ return 'bgra8unorm' } } } });
  globalThis.__mockcanvas = {
    width: 640, height: 480,
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
       (check 1 "configure:bgra8unorm:opaque")
       ;; the depth buffer comes up with the canvas
       (check 2 "texture:640x480:depth24plus")))

;; resources: a pipeline over one interleaved buffer, and the buffer
(gpu-pipeline! 0 "@vertex fn vs() {} @fragment fn fs() {}"
               24 "float32x2,float32x4")
(gpu-buffer! 1 144)
(define resource-ok
  (and (check 3 "module:39")
       (check 4 "pipeline:24:float32x2@0>0|float32x4@8>1:bgra8unorm")
       (check 5 "depth:depth24plus:less")
       (check 6 "buffer:144:40")))

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
  (and (check 7 "writeBuffer:B1:144:0.25:-1.50")
       (check 8 "beginPass:clear:0.02:0.03:0.05:1.00:clear")
       (check 9 "setPipeline:PL1")
       (check 10 "setVbuf:0:B1")
       (check 11 "draw:6")
       (check 12 "endPass")
       (check 13 "submit:1")))

;; a clear-only frame still opens (and clears) the pass
(gpu-begin!)
(gpu-clear! 1.0 0.0 0.0 1.0)
(gpu-flush!)
(define clear-ok
  (and (check 14 "beginPass:clear:1.00:0.00:0.00:1.00:clear")
       (check 15 "endPass")
       (check 16 "submit:1")))

;; indexed geometry through a bind group: the 3D shape of a frame
(gpu-index! 5 72)
(gpu-uniforms! 6 128)
(gpu-bindgroup! 7 0 6)
(gpu-begin!)
(gpu-clear! 0.0 0.0 0.0 1.0)
(gpu-use-pipeline! 0)
(gpu-set-group! 7)
(gpu-bind-vbuf! 1)
(gpu-bind-ibuf! 5)
(gpu-buffer-data! 6 4096 128)           ; the uniform struct
(gpu-draw-indexed! 36)
(gpu-flush!)
(define indexed-ok
  (and (check 17 "buffer:72:24")
       (check 18 "buffer:128:72")
       (check 19 "bindgroup:L0:0=B3")
       (check 20 "writeBuffer:B3:128:0.25:-1.50")
       (check 21 "beginPass:clear:0.00:0.00:0.00:1.00:clear")
       (check 22 "setPipeline:PL1")
       (check 23 "setGroup:0:G1")
       (check 24 "setVbuf:0:B1")
       (check 25 "setIbuf:B2:uint16")
       (check 26 "drawIndexed:36")
       (check 27 "endPass")
       (check 28 "submit:1")))

;; compute: a storage buffer both passes share, one dispatch, then
;; an instanced draw off two vertex streams
(gpu-storage! 8 1600)
(gpu-compute! 9 "@compute fn cs() {}")
(gpu-compute-group! 10 9 8 6)
(gpu-pipeline2! 11 "@vertex fn vs() {} @fragment fn fs() {}"
                8 "float32x2" 16 "float32x2,float32x2")
(gpu-begin!)
(gpu-buffer-data! 8 4096 16)
(gpu-dispatch! 9 10 25)
(gpu-clear! 0.0 0.0 0.0 1.0)
(gpu-use-pipeline! 11)
(gpu-bind-vbuf! 1)
(gpu-bind-vbuf2! 8)
(gpu-draw-instanced! 3 100)
(gpu-flush!)
(define compute-ok
  (and (check 29 "buffer:1600:168")     ; VERTEX | STORAGE | COPY_DST
       (check 30 "module:19")
       (check 31 "computePipeline:cs")
       (check 32 "bindgroup:CL0:0=B4|1=B3")
       (check 33 "module:39")
       (check 34 "pipeline:8:float32x2@0>0:bgra8unorm")
       (check 35 "instance:16:float32x2@0>1|float32x2@8>2")
       (check 36 "depth:depth24plus:less")
       (check 37 "writeBuffer:B4:16:0.25:-1.50")
       (check 38 "csPipeline:CP1")
       (check 39 "csGroup:0:G2")
       (check 40 "dispatch:25")
       (check 41 "csEnd")
       (check 42 "beginPass:clear:0.00:0.00:0.00:1.00:clear")
       (check 43 "setPipeline:PL2")
       (check 44 "setVbuf:0:B1")
       (check 45 "setVbuf:1:B4")
       (check 46 "draw:3:100")
       (check 47 "endPass")
       (check 48 "submit:1")))

;; textures: rgba8 + one writeTexture out of staging, and the
;; textured bind group in (gfx wgsl)'s binding order
(gpu-texture! 12 64 64)
(%mem-u8-set! 4096 200)
(gpu-texture-data! 12 4096 64 64)
(gpu-sampler! 13)
(gpu-texgroup! 14 0 6 13 12)
(gpu-texgroup! 15 0 -1 13 12)           ; no scalar uniforms
(define tex-ok
  (and (check 49 "texture:64x64:rgba8unorm")
       (check 50 "writeTexture:T2:16384:256:64x64")
       (check 51 "sampler:linear")
       (check 52 "bindgroup:L0:0=B3|1=S1|2=T2v")
       (check 53 "bindgroup:L0:0=S1|1=T2v")))

;; render bundles: draws freeze once, frames just execute them
(gpu-begin!)
(gpu-use-pipeline! 0)
(gpu-set-group! 7)
(gpu-bind-vbuf! 1)
(gpu-bind-ibuf! 5)
(gpu-draw-indexed! 36)
(gpu-bundle! 16)
(gpu-begin!)
(gpu-clear! 0.0 0.0 0.0 1.0)
(gpu-execute! 16)
(gpu-flush!)
(define bundle-ok
  (and (check 54 "bundleEnc:bgra8unorm:depth24plus")
       (check 55 "b.setPipeline:PL1")
       (check 56 "b.setGroup:0:G1")
       (check 57 "b.setVbuf:0:B1")
       (check 58 "b.setIbuf:B2:uint16")
       (check 59 "b.drawIndexed:36")
       (check 60 "b.finish")
       (check 61 "beginPass:clear:0.00:0.00:0.00:1.00:clear")
       (check 62 "exec:BN1")
       (check 63 "endPass")
       (check 64 "submit:1")))

;; GPU-driven draws: the indirect buffer's usage carries INDIRECT |
;; STORAGE, the N-buffer compute group binds in list order, and the
;; indirect opcodes decode buffer + offset
(define base-i (js->number (js-get log "length")))
(gpu-indirect! 17 20)
(gpu-compute-group*! 18 9 "8,17,6")
(gpu-begin!)
(gpu-use-pipeline! 0)
(gpu-bind-vbuf! 1)
(gpu-bind-ibuf! 5)
(gpu-draw-indexed-indirect! 17 0)
(gpu-draw-indirect! 17 4)
(gpu-flush!)
(define indirect-ok
  (and (check base-i "buffer:20:392")            ; INDIRECT|STORAGE|COPY_DST
       (check (+ base-i 1) "bindgroup:CL0:0=B4|1=B5|2=B3")
       (check (+ base-i 3) "setPipeline:PL1")
       (check (+ base-i 4) "setVbuf:0:B1")
       (check (+ base-i 5) "setIbuf:B2:uint16")
       (check (+ base-i 6) "drawIndexedIndirect:B5:0")
       (check (+ base-i 9) "drawIndirect:B5:4")))

(and attach-ok resource-ok frame-ok clear-ok indexed-ok compute-ok
     tex-ok bundle-ok indirect-ok)
