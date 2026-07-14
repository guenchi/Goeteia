;; expect: #t
;; (gfx sgpu): the declarative scene on the WebGPU mock -- groups
;; per geometry, storage instances, one cull dispatch and one
;; indirect draw each, and signals invalidating only their group.
(import (rnrs) (web js) (gfx fx) (gfx gpu) (gfx mat) (gfx sgpu)
        (web reactive))

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
      push('texture', d.size.join(','), d.format,
           d.mipLevelCount || 1);
      const id = 'T' + (this._t = (this._t || 0) + 1);
      return { id, createView(o){ return { id: id + 'v' } } } },
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
      push('depth', d.depthStencil.format, d.depthStencil.depthCompare,
           d.depthStencil.depthWriteEnabled ? 1 : 0,
           d.fragment.targets[0].blend ? 'blend' : 'opaque');
      return { id: 'PL' + (this._p = (this._p || 0) + 1),
               getBindGroupLayout(i){ return { id: 'L' + i } } } },
    createBuffer(d){
      push('buffer', d.size, d.usage);
      return { id: 'B' + (this._b = (this._b || 0) + 1),
               mapAsync(m){ push('mapAsync', m); return { then(f){ f(); return this } } },
               getMappedRange(){ return new BigInt64Array([1000000n, 5200000n]).buffer },
               unmap(){ push('unmap') } } },
    createSampler(d){
      push('sampler', d.magFilter);
      return { id: 'S' + (this._s = (this._s || 0) + 1) } },
    createQuerySet(d){
      push('querySet', d.type, d.count);
      return { id: 'QS' + (this._qs = (this._qs || 0) + 1) } },
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
        resolveQuerySet(qs, a, b, buf, o){ push('resolveQS', qs.id, buf.id) },
        copyBufferToBuffer(src, so, dst, dofs, n){ push('copyB2B', src.id, dst.id, n) },
        beginComputePass(){
          return { setPipeline(p){ push('csPipeline', p.id) },
                   setBindGroup(i, g){ push('csGroup', i, g.id) },
                   dispatchWorkgroups(n){ push('dispatch', n) },
                   end(){ push('csEnd') } } },
        finish(){ return {} } } } };
  const adapter = {
    features: { has(n){ return n === 'timestamp-query' } },
    requestDevice(opts){ return { then(f){ return f(device) } } } };
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
(define (log-len) (js->number (js-get log "length")))
(define (count-log p)
  (let ((n (log-len)))
    (let loop ((i 0) (c 0))
      (if (= i n)
          c
          (loop (+ i 1)
                (if (and (<= (string-length p) (string-length (entry i)))
                         (string=? p (substring (entry i) 0
                                                (string-length p))))
                    (+ c 1)
                    c))))))

(define ready #f)
(gpu-attach! (js-get (js-global) "__mockcanvas") (lambda () (set! ready #t)))

(define swing (signal 0.0))
(define sc
  (sgl-gpu
   (camera (@ (fov 0.9) (position 0.0 2.0 8.0) (look-at 0.0 0.0 0.0)))
   (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
   (group (@ (rotation-y ,(signal-ref swing)))
     (mesh (@ (geometry (box 1 1 1)) (position 1.0 0.0 0.0)
              (color 1.0 0.0 0.0))))
   (mesh (@ (geometry (box 1 1 1)) (position -2.0 0.0 0.0)))
   (mesh (@ (geometry (sphere 1.0 8 4)) (position 3.0 0.0 0.0)))))

(sgpu-init! sc (js-get (js-global) "__mockcanvas"))

;; two geometry groups: the two boxes share one, the sphere its own
(define init-ok
  (and ready (sgpu-scene? sc)
       ;; 2 groups x (vbuf + ibuf + src storage + dst storage +
       ;; indirect) + env uniform = 11 buffers
       (= (count-log "buffer:") 11)))

(define d0 (count-log "dispatch"))
(define i0 (count-log "drawIndexedIndirect"))
(define w0 (count-log "writeBuffer"))
(gpu-begin!)
(gpu-clear! 0.0 0.0 0.0 1.0)
(sgpu-draw! sc)
(gpu-flush!)
(define frame1-ok
  (and (= (- (count-log "dispatch") d0) 2)          ; one cull per group
       (= (- (count-log "drawIndexedIndirect") i0) 2)))

;; frame 2, nothing moved: no instance re-upload (env + 2 arg resets
;; only), same dispatch/draw shape
(define w1 (count-log "writeBuffer"))
(gpu-begin!)
(gpu-clear! 0.0 0.0 0.0 1.0)
(sgpu-draw! sc)
(gpu-flush!)
(define static-ok
  (= (- (count-log "writeBuffer") w1) 3))

;; frame 3, the signal swings: exactly one group re-uploads
(signal-set! swing 1.0)
(define w2 (count-log "writeBuffer"))
(gpu-begin!)
(gpu-clear! 0.0 0.0 0.0 1.0)
(sgpu-draw! sc)
(gpu-flush!)
(define dirty-ok
  (= (- (count-log "writeBuffer") w2) 4))

;; ---- translucency: a group with alpha<1 draws blended, depth
;; writes off, after the opaque groups ----
(define sctr
  (sgl-gpu
   (camera (@ (fov 0.9) (position 0.0 0.0 8.0) (look-at 0.0 0.0 0.0)))
   (light (@ (direction 0.0 1.0 0.0) (ambient 0.25)))
   (mesh (@ (geometry (box 1 1 1)) (position -2.0 0.0 0.0)))   ; opaque
   (mesh (@ (geometry (sphere 1.0 8 4)) (position 2.0 0.0 0.0)
            (color 0.3 0.6 0.9 0.4)))))                         ; glass
(define tr-base (log-len))
(sgpu-init! sctr (js-get (js-global) "__mockcanvas"))
(define tr-init-ok
  ;; among the pipelines, exactly two carry a blend target with
  ;; depth writes disabled (the blended lit + tex)
  (= (count-log "depth:depth24plus:less:0:blend") 4))
(define d0 (count-log "drawIndexedIndirect"))
(gpu-begin!) (gpu-clear! 0.0 0.0 0.0 1.0) (sgpu-draw! sctr) (gpu-flush!)
(define tr-draw-ok
  ;; two indirect draws: the opaque box, then the glass sphere on
  ;; the blend pipeline
  (= (- (count-log "drawIndexedIndirect") d0) 2))

(and init-ok frame1-ok static-ok dirty-ok tr-init-ok tr-draw-ok)
