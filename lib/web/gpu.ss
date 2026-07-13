;; A WebGPU backend: the (web gl) architecture -- resources in a JS
;; slot table, ONE bridge call replaying a command region from the
;; staging memory each frame -- carried over to the other API.
;; What exists: attach (async: the adapter/device handshake calls
;; you back, and a depth24plus buffer sized to the canvas comes up
;; with it), render pipelines from WGSL source (one interleaved
;; vertex buffer, depth test on), vertex / index (u16) / uniform
;; buffers, bind groups over a uniform buffer, per-frame uploads out
;; of staging memory, clear, draw and drawIndexed.
;;
;;   (gpu-attach! canvas (lambda () ...ready...))
;;   (gpu-pipeline! 0 WGSL 24 "float32x3,float32x3")
;;   (gpu-buffer! 1 vbytes) (gpu-index! 2 ibytes)
;;   (gpu-uniforms! 3 64) (gpu-bindgroup! 4 0 3)
;;   ... per frame:
;;   (gpu-begin!)
;;   (gpu-clear! 0.02 0.02 0.05 1.0)
;;   (gpu-use-pipeline! 0) (gpu-set-group! 4)
;;   (gpu-bind-vbuf! 1) (gpu-bind-ibuf! 2)
;;   (gpu-buffer-data! 3 ubase 64)        ; the uniform struct, one write
;;   (gpu-draw-indexed! icount)
;;   (gpu-flush!)                         ; one submit
;;
;; The mapping:
;;   gl slot table          -> the same table over GPUBuffer /
;;                             GPURenderPipeline / GPUBindGroup
;;                             (later: GPUTexture, GPUSampler)
;;   command words          -> decoded into render-pass method calls;
;;                             the pass opens lazily at the first draw
;;                             with the frame's clear color, so state
;;                             commands may come in any order
;;   cmd-buffer-data!       -> queue.writeBuffer straight out of the
;;                             staging ArrayBuffer (queue-ordered
;;                             before the frame's submit)
;;   cmd-uniform*!          -> no per-name uniforms in WebGPU: the
;;                             shader's whole uniform struct is ONE
;;                             buffer written by one gpu-buffer-data!
;;                             and bound as @group(0) @binding(0)
;;   cmd-flush!             -> pass.end() + queue.submit(one encoder)
;;   still missing          -> textures + samplers, multiple bind
;;                             groups, compute passes, and WGSL
;;                             rendered from the (web glsl) forms
;;
;; The command region is the same staging words (web gl) uses; a page
;; drives one backend or the other, not both at once.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (web gpu)
  (export gpu-attach! gpu-pipeline! gpu-buffer! gpu-index!
          gpu-uniforms! gpu-bindgroup!
          gpu-begin! gpu-flush!
          gpu-clear! gpu-use-pipeline! gpu-bind-vbuf! gpu-bind-ibuf!
          gpu-set-group! gpu-buffer-data! gpu-draw! gpu-draw-indexed!)
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
     "        const GT = globalThis.GPUTextureUsage"
     "                 || { RENDER_ATTACHMENT: 16 };"
     "        st.depth = dev.createTexture({"
     "          size: [canvas.width, canvas.height],"
     "          format: 'depth24plus',"
     "          usage: GT.RENDER_ATTACHMENT });"
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
     "      depthStencil: { format: 'depth24plus',"
     "                      depthWriteEnabled: true,"
     "                      depthCompare: 'less' },"
     "      primitive: { topology: 'triangle-list' } }); },"
     "  buffer(slot, bytes, kind) {"       ; 0 vertex, 1 index, 2 uniform
     "    const GB = globalThis.GPUBufferUsage"
     "             || { VERTEX: 32, INDEX: 16, UNIFORM: 64, COPY_DST: 8 };"
     "    slots[slot] = st.dev.createBuffer({"
     "      size: bytes,"
     "      usage: (kind === 1 ? GB.INDEX : kind === 2 ? GB.UNIFORM"
     "              : GB.VERTEX) | GB.COPY_DST }); },"
     "  bindgroup(slot, pslot, ubslot) {"
     "    slots[slot] = st.dev.createBindGroup({"
     "      layout: slots[pslot].getBindGroupLayout(0),"
     "      entries: [{ binding: 0,"
     "                  resource: { buffer: slots[ubslot] } }] }); },"
     "  replay(count) {"
     "    const dv = new DataView(memory.buffer);"
     "    let p = 0;"
     "    const u = () => { const v = dv.getUint32(p, true); p += 4; return v; };"
     "    const f = () => { const v = dv.getFloat32(p, true); p += 4; return v; };"
     "    const enc = st.dev.createCommandEncoder();"
     "    let clear = { r: 0, g: 0, b: 0, a: 1 };"
     "    let pipeline = null, vbuf = null, ibuf = null;"
     "    let group = null, pass = null;"
     "    const open = () => {"
     "      if (!pass) pass = enc.beginRenderPass({"
     "        colorAttachments: [{"
     "          view: st.ctx.getCurrentTexture().createView(),"
     "          loadOp: 'clear', clearValue: clear, storeOp: 'store' }],"
     "        depthStencilAttachment: {"
     "          view: st.depth.createView(),"
     "          depthClearValue: 1.0,"
     "          depthLoadOp: 'clear', depthStoreOp: 'store' } }); };"
     "    const ready = () => {"
     "      open(); pass.setPipeline(pipeline);"
     "      if (group) pass.setBindGroup(0, group);"
     "      pass.setVertexBuffer(0, vbuf); };"
     "    const end = p + count * 4;"
     "    while (p < end) {"
     "      switch (u()) {"
     "        case 1: clear = { r: f(), g: f(), b: f(), a: f() }; break;"
     "        case 2: pipeline = slots[u()]; break;"
     "        case 3: vbuf = slots[u()]; break;"
     "        case 4: { const s = slots[u()], base = u(), bytes = u();"
     "                  st.q.writeBuffer(s, 0, memory.buffer, base, bytes);"
     "                  break; }"
     "        case 5: ready(); pass.draw(u()); break;"
     "        case 6: group = slots[u()]; break;"
     "        case 7: ibuf = slots[u()]; break;"
     "        case 8: ready(); pass.setIndexBuffer(ibuf, 'uint16');"
     "                pass.drawIndexed(u()); break;"
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
    (js-method $gpu "buffer" slot bytes 0))
  (define (gpu-index! slot bytes)       ; u16 indices
    (js-method $gpu "buffer" slot bytes 1))
  ;; one uniform buffer per pipeline: the WGSL declares
  ;; @group(0) @binding(0) var<uniform> ... and the whole struct
  ;; rides one gpu-buffer-data! per frame
  (define (gpu-uniforms! slot bytes)
    (js-method $gpu "buffer" slot bytes 2))
  (define (gpu-bindgroup! slot pslot ubslot)
    (js-method $gpu "bindgroup" slot pslot ubslot))

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
  (define (gpu-set-group! slot) ($gpu-u! 6) ($gpu-u! slot))
  (define (gpu-bind-ibuf! slot) ($gpu-u! 7) ($gpu-u! slot))
  (define (gpu-draw-indexed! count) ($gpu-u! 8) ($gpu-u! count))

  (define (gpu-flush!)
    (js-method $gpu "replay" (quotient $gpu-p 4))))
