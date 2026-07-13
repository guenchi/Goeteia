;; A WebGPU backend, proof of concept: the (web gl) architecture --
;; resources in a JS slot table, ONE bridge call replaying a command
;; region from the staging memory each frame -- carried over to the
;; other API.  What exists today: attach (async: the adapter/device
;; handshake calls you back), a render pipeline from WGSL source with
;; one interleaved vertex buffer, vertex buffers, per-frame buffer
;; upload out of staging memory, clear and draw.
;;
;;   (gpu-attach! canvas (lambda () ...ready...))
;;   (gpu-pipeline! 0 WGSL 24 "float32x2,float32x4")
;;   (gpu-buffer! 1 (* N 24))
;;   ... per frame:
;;   (gpu-begin!)
;;   (gpu-clear! 0.02 0.02 0.05 1.0)
;;   (gpu-use-pipeline! 0) (gpu-bind-vbuf! 1)
;;   (gpu-buffer-data! 1 base bytes)      ; staging -> queue.writeBuffer
;;   (gpu-draw! (* N 3))
;;   (gpu-flush!)                         ; one submit
;;
;; The mapping, and what a full backend adds:
;;   gl slot table          -> the same table over GPUBuffer /
;;                             GPURenderPipeline (later: GPUTexture,
;;                             GPUBindGroup, GPUSampler)
;;   command words          -> decoded into render-pass method calls;
;;                             the pass opens lazily at the first draw
;;                             with the frame's clear color, so state
;;                             commands may come in any order
;;   cmd-buffer-data!       -> queue.writeBuffer straight out of the
;;                             staging ArrayBuffer (queue-ordered
;;                             before the frame's submit)
;;   cmd-flush!             -> pass.end() + queue.submit(one encoder)
;;   uniforms               -> the real gap: WebGPU has no uniform1f;
;;                             a full backend packs a uniform struct
;;                             into one UBO write per frame and binds
;;                             it as a bind group (the (web glsl)
;;                             forms would render to WGSL)
;;
;; The command region is the same staging words (web gl) uses; a page
;; drives one backend or the other, not both at once.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web gpu)
  (export gpu-attach! gpu-pipeline! gpu-buffer!
          gpu-begin! gpu-flush!
          gpu-clear! gpu-use-pipeline! gpu-bind-vbuf!
          gpu-buffer-data! gpu-draw!)
  (import (rnrs) (web js))

  (define $gpu #f)

  (define $gpu-src
    (string-append
     "globalThis.__goeteia_gpu = (canvas, memory) => {"
     " const st = { dev: null, q: null, ctx: null, fmt: null };"
     " const slots = [];"
     " return {"
     "  attach(cb) {"
     "    navigator.gpu.requestAdapter()"
     "      .then(ad => ad.requestDevice())"
     "      .then(dev => {"
     "        st.dev = dev; st.q = dev.queue;"
     "        st.ctx = canvas.getContext('webgpu');"
     "        st.fmt = navigator.gpu.getPreferredCanvasFormat();"
     "        st.ctx.configure({ device: dev, format: st.fmt,"
     "                           alphaMode: 'opaque' });"
     "        cb(); }); },"
     "  pipeline(slot, code, stride, fmts) {"
     "    const mod = st.dev.createShaderModule({ code });"
     "    let off = 0, loc = 0;"
     "    const attrs = String(fmts).split(',').map(f => {"
     "      const a = { format: f, offset: off, shaderLocation: loc++ };"
     "      off += Number(f.replace(/.*x/, '')) * 4;"
     "      return a; });"
     "    slots[slot] = st.dev.createRenderPipeline({"
     "      layout: 'auto',"
     "      vertex: { module: mod, entryPoint: 'vs',"
     "                buffers: [{ arrayStride: stride, attributes: attrs }] },"
     "      fragment: { module: mod, entryPoint: 'fs',"
     "                  targets: [{ format: st.fmt }] },"
     "      primitive: { topology: 'triangle-list' } }); },"
     "  buffer(slot, bytes) {"
     "    const GB = globalThis.GPUBufferUsage"
     "             || { VERTEX: 32, COPY_DST: 8 };"  ; headless mocks
     "    slots[slot] = st.dev.createBuffer({"
     "      size: bytes,"
     "      usage: GB.VERTEX | GB.COPY_DST }); },"
     "  replay(count) {"
     "    const dv = new DataView(memory.buffer);"
     "    let p = 0;"
     "    const u = () => { const v = dv.getUint32(p, true); p += 4; return v; };"
     "    const f = () => { const v = dv.getFloat32(p, true); p += 4; return v; };"
     "    const enc = st.dev.createCommandEncoder();"
     "    let clear = { r: 0, g: 0, b: 0, a: 1 };"
     "    let pipeline = null, vbuf = null, pass = null;"
     "    const open = () => {"
     "      if (!pass) pass = enc.beginRenderPass({ colorAttachments: [{"
     "        view: st.ctx.getCurrentTexture().createView(),"
     "        loadOp: 'clear', clearValue: clear, storeOp: 'store' }] }); };"
     "    const end = p + count * 4;"
     "    while (p < end) {"
     "      switch (u()) {"
     "        case 1: clear = { r: f(), g: f(), b: f(), a: f() }; break;"
     "        case 2: pipeline = slots[u()]; break;"
     "        case 3: vbuf = slots[u()]; break;"
     "        case 4: { const s = slots[u()], base = u(), bytes = u();"
     "                  st.q.writeBuffer(s, 0, memory.buffer, base, bytes);"
     "                  break; }"
     "        case 5: open(); pass.setPipeline(pipeline);"
     "                pass.setVertexBuffer(0, vbuf); pass.draw(u()); break;"
     "      }"
     "    }"
     "    open();"                       ; a clear-only frame still clears
     "    pass.end();"
     "    st.q.submit([enc.finish()]); } }; };"))

  ;; the device handshake is asynchronous: k runs when the canvas is
  ;; configured and resources may be created
  (define (gpu-attach! canvas k)
    (js-eval $gpu-src)
    (set! $gpu (js-call (js-get (js-global) "__goeteia_gpu") (js-undefined)
                        canvas (js-get (js-global) "__goeteia_mem")))
    (js-method $gpu "attach" k))

  ;; a render pipeline from one WGSL module (entry points vs / fs)
  ;; over one interleaved vertex buffer: stride in bytes, fmts a
  ;; comma-joined GPUVertexFormat list bound to locations 0,1,...
  (define (gpu-pipeline! slot wgsl stride fmts)
    (js-method $gpu "pipeline" slot wgsl stride fmts))
  (define (gpu-buffer! slot bytes)
    (js-method $gpu "buffer" slot bytes))

  ;; ---- the encoder: words into the staging memory, gl-style ----
  (define $gpu-p 0)
  (define (gpu-begin!) (set! $gpu-p 0))
  (define ($gpu-u! v) (%mem-i32-set! $gpu-p v) (set! $gpu-p (+ $gpu-p 4)))
  (define ($gpu-f! v)
    (%mem-f32-set! $gpu-p (if (flonum? v) v (exact->inexact v)))
    (set! $gpu-p (+ $gpu-p 4)))

  (define (gpu-clear! r g b a)
    ($gpu-u! 1) ($gpu-f! r) ($gpu-f! g) ($gpu-f! b) ($gpu-f! a))
  (define (gpu-use-pipeline! slot) ($gpu-u! 2) ($gpu-u! slot))
  (define (gpu-bind-vbuf! slot) ($gpu-u! 3) ($gpu-u! slot))
  (define (gpu-buffer-data! slot base bytes)
    ($gpu-u! 4) ($gpu-u! slot) ($gpu-u! base) ($gpu-u! bytes))
  (define (gpu-draw! verts) ($gpu-u! 5) ($gpu-u! verts))

  (define (gpu-flush!)
    (js-method $gpu "replay" (quotient $gpu-p 4))))
