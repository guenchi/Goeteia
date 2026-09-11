;; expect: 4 ok; 20 ok; 34 ok; 35 ok; end
;; REGRESSION GUARD (written as a red witness at 4a439b6; green since).
;; The defect as it then was: the HZB pyramid and the depth-sorting cull
;; pipeline live at hard-coded slots 250 and 251, and geometry groups
;; are handed consecutive slots from 9 upward with no ceiling. -> Enough
;; groups and the group allocator walks over both.
;;
;; MEASURED BOUNDARY: 34 groups work, 35 does not.  It is not
;; derived.  Reading "eight slots each from 9" out of the source
;; predicts the 31st group, and that is wrong -- 31, 32, 33 and 34 all
;; survive.  The layout is not the arithmetic the comment suggests, and
;; a cell asserting the predicted number would have been red for the
;; wrong count and would have looked right.
;;
;; The overwrite is not detected.  The next thing to use the HZB
;; slot finds whatever the group put there and asks it for a texture
;; view, which is a scene that fails on its 31st distinct mesh with a
;; message about a missing method -- naming the symptom, in the render
;; loop, with nothing pointing at the allocator.
;;
;; Two allocators, one address space, and only one of them knows
;; about the other: the group allocator counts upward from 9 with no
;; ceiling, and the two reserved slots were chosen to be "far away".
;; Far away is a distance, not an invariant.
;;
;; The controls are scenes below the collision, which must keep working
;; -- they are what says the COUNT is the variable, since the scenes
;; differ in nothing else.
;;
;; THE FAILURE CANNOT BE CAUGHT.  It surfaces as a host JS error
;; ("slots[...].createView is not a function"), not a Scheme condition,
;; so `guard` goes straight past it exactly as it goes past a wasm
;; trap.  -> This file cannot collect verdicts and print them at the
;; end; it prints each count as that count survives, and the run simply
;; stops where it breaks.  The expected line is the whole sequence, so
;; a short answer names the count that failed.
(import (rnrs) (web js) (gfx fx) (gfx gpu) (gfx mat) (gfx sgpu)
        (web reactive))
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

(define (step n)
  (let ((sc (scene-of n)))
    (sgpu-init! sc (js-get (js-global) "__mockcanvas"))
    (sgpu-draw! sc))
  (display n) (display " ok;")
  (display " "))

;; n distinct geometries, so each takes a group of its own.  The
;; geometry spec is data rather than code, so the scene can be built
;; programmatically -- which is what makes the group COUNT the variable
;; instead of a hand-written wall of meshes.
(define (scene-of n)
  ($sgpu-build
   (append
    (list '(camera (@ (fov 0.9) (position 0.0 0.0 400.0) (look-at 0.0 0.0 0.0)
                      (near 0.1) (far 900.0)))
          '(light (@ (direction 0.0 1.0 0.0) (ambient 0.25))))
    (let build ((i 0) (acc '()))
      (if (= i n)
          (reverse acc)
          (build (+ i 1)
                 (cons (list 'mesh
                             (list '@ (list 'geometry (list 'box (+ 1 i) 1 1))
                                   (list 'position (exact->inexact i) 0.0 0.0)))
                       acc)))))
   '()))


;; controls first, then the counts that collide -- the run ends where
;; it breaks and the transcript says where
(step 4)
(step 20)
(step 34)
(step 35)
(display "end")

;; WHAT THIS CELL DOES NOT SEE, measured rather than reasoned.
;;
;; It pins whether the group walk COLLIDED with the reserved slots.
;; It does not pin how much room was left.  Shortening the reservation
;; by one or by two goes unnoticed here; three is where it is caught:
;;
;;     top - 1   passes      top - 2   passes      top - 3   caught
;;
;; So the highest slot the last group actually writes is three below
;; where the reservation is placed, and two slots of slack sit between
;; them.  A reservation one short of correct is still correct in
;; effect, and this cell would report every count passing.
;;
;; The obvious repair was tried and did not move the boundary: a group
;; takes an extra slot when it carries a texture, so a textured mesh in
;; the last group ought to reach further up, and with one added top-1
;; and top-2 still passed.
;;
;; That reading does NOT establish that the extra slot goes unwritten,
;; and the first draft of this comment said it did.  The texture slot a
;; fixture names has to already hold a real texture; pointing at an
;; empty one either fails in some other way or is never classified as
;; textured at all, and in the second case the slot-taking code never
;; runs.  "Ran and made no difference" and "never ran" are the same
;; reading here, and nothing was done to tell them apart.
;;
;; So what is known is the boundary, three slots below the reservation.
;; Whoever revisits this starts by putting a real texture in the slot
;; and confirming the last group is classified as textured, BEFORE
;; drawing any conclusion from a boundary that did not move.
;;
;; The margin is real and it comes from the reservation being derived
;; from the walk rather than placed near it.  That derivation is an
;; argument in lib/gfx/sgpu.ss, and this cell is not evidence for it.
