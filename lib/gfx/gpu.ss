;; Copyright 2026 guenchi
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

;; A WebGPU backend: the (gfx gl) architecture -- resources in a JS
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
;;   transform feedback     -> gpu-dispatch!: a compute pass mutates
;;                             a storage buffer that doubles as the
;;                             render pass's vertex stream
;;                             (gpu-storage!), all in one submit --
;;                             encode dispatches before the draws
;;   still missing          -> textures + samplers, multiple bind
;;                             groups per pipeline
;;
;; The command words go into a region of the staging memory: from a
;; base (0 unless gpu-region! moves it), with an optional byte limit,
;; as (gfx gl)'s cmd-region!.  (gfx gpu) sets no limit itself;
;; sgpu-init! sets [0, 64 KiB), the same region fx-init! gives (gfx gl),
;; whose allocator hands out the bytes above it.  A page drives one
;; backend or the other, not both at once.
;;
(library (gfx gpu)
  (export gpu-attach! gpu-pipeline! gpu-pipeline2! gpu-pipeline2-blend!
          gpu-buffer! gpu-index! gpu-uniforms! gpu-storage!
          gpu-indirect! gpu-compute-group*!
          gpu-draw-indexed-indirect! gpu-draw-indirect!
          gpu-hzb-init! gpu-end-pass! gpu-hzb! gpu-compute-groupx!
          gpu-texture! gpu-texture-data! gpu-sampler!
          gpu-bindgroup! gpu-texgroup!
          gpu-compute! gpu-compute-group!
          gpu-begin! gpu-flush! gpu-region! gpu-pos
          gpu-stamp gpu-stamp-holds? gpu-stamp-replayed?
          gpu-clear! gpu-use-pipeline! gpu-bind-vbuf! gpu-bind-vbuf2!
          gpu-bind-ibuf! gpu-set-group! gpu-buffer-data!
          gpu-draw! gpu-draw-indexed! gpu-draw-instanced!
          gpu-dispatch! gpu-bundle! gpu-execute!
          gpu-gpu-timer! gpu-gpu-ms)
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
     "      .then(ad => {"
     "        st.ts = ad.features && ad.features.has('timestamp-query');"
     "        return ad.requestDevice(st.ts"
     "          ? { requiredFeatures: ['timestamp-query'] } : {}); })"
     "      .then(dev => {"
     "        st.dev = dev; st.q = dev.queue;"
     "        st.ctx = canvas.getContext('webgpu');"
     "        st.fmt = navigator.gpu.getPreferredCanvasFormat();"
     "        st.ctx.configure({ device: dev, format: st.fmt,"
     "                           alphaMode: 'opaque' });"
     "        const GT = globalThis.GPUTextureUsage"
     "                 || { RENDER_ATTACHMENT: 16, TEXTURE_BINDING: 4 };"
     "        st.depth = dev.createTexture({"
     "          size: [canvas.width, canvas.height],"
     "          format: 'depth24plus',"
     "          usage: GT.RENDER_ATTACHMENT | (GT.TEXTURE_BINDING || 4) });"
     "        cb(); }); },"
     "  parseAttrs(fmts, loc) {"
     "    const size = f => {"
     "      const m = /^(uint|sint|unorm|snorm|float)(8|16|32)(x(2|3|4))?$/.exec(f);"
     "      if (!m) throw new Error('gpu: unknown vertex format: ' + f);"
     "      const bits = Number(m[2]), n = m[4] ? Number(m[4]) : 1;"
     "      if (bits !== 32 && n !== 2 && n !== 4)"
     "        throw new Error('gpu: 8- and 16-bit formats exist only as x2 and x4: ' + f);"
     "      if (bits === 8 && m[1] === 'float')"
     "        throw new Error('gpu: there is no 8-bit float format: ' + f);"
     "      if (bits === 32 && (m[1] === 'unorm' || m[1] === 'snorm'))"
     "        throw new Error('gpu: normalized formats are 8- and 16-bit only: ' + f);"
     "      return bits / 8 * n; };"
     "    let off = 0;"
     "    const attrs = String(fmts).split(',').map(f => {"
     "      const a = { format: f, offset: off, shaderLocation: loc++ };"
     "      off += size(f);"
     "      return a; });"
     "    return attrs; },"
     "  pipeline(slot, code, stride, fmts) {"
     "    const mod = st.dev.createShaderModule({ code });"
     "    const attrs = this.parseAttrs(fmts, 0);"
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
     "  pipeline2(slot, code, vstride, vfmts, istride, ifmts) {"
     "    this.pipeline2b(slot, code, vstride, vfmts, istride, ifmts, 0); },"
     "  pipeline2b(slot, code, vstride, vfmts, istride, ifmts, blend) {"
     "    const mod = st.dev.createShaderModule({ code });"
     "    const va = this.parseAttrs(vfmts, 0);"
     "    const ia = this.parseAttrs(ifmts, va.length);"
     "    const target = blend"
     "      ? { format: st.fmt, blend: {"
     "            color: { srcFactor: 'src-alpha',"
     "                     dstFactor: 'one-minus-src-alpha' },"
     "            alpha: { srcFactor: 'one',"
     "                     dstFactor: 'one-minus-src-alpha' } } }"
     "      : { format: st.fmt };"
     "    slots[slot] = st.dev.createRenderPipeline({"
     "      layout: 'auto',"
     "      vertex: { module: mod, entryPoint: 'vs', buffers: ["
     "        { arrayStride: vstride, attributes: va },"
     "        { arrayStride: istride, stepMode: 'instance',"
     "          attributes: ia }] },"
     "      fragment: { module: mod, entryPoint: 'fs',"
     "                  targets: [target] },"
     "      depthStencil: { format: 'depth24plus',"
     "                      depthWriteEnabled: !blend,"
     "                      depthCompare: 'less' },"
     "      primitive: { topology: 'triangle-list' } }); },"
     "  buffer(slot, bytes, kind) {"  ; 0 vtx, 1 idx, 2 uniform,
     "    const GB = globalThis.GPUBufferUsage" ; 3 storage, 4 indirect
     "             || { VERTEX: 32, INDEX: 16, UNIFORM: 64,"
     "                  STORAGE: 128, COPY_DST: 8, INDIRECT: 256 };"
     "    slots[slot] = st.dev.createBuffer({"
     "      size: bytes,"
     "      usage: (kind === 1 ? GB.INDEX : kind === 2 ? GB.UNIFORM"
     "              : kind === 3 ? (GB.VERTEX | GB.STORAGE)"
     "              : kind === 4 ? (GB.INDIRECT | GB.STORAGE)"
     "              : GB.VERTEX) | GB.COPY_DST }); },"
     "  bindgroup(slot, pslot, ubslot) {"
     "    slots[slot] = st.dev.createBindGroup({"
     "      layout: slots[pslot].getBindGroupLayout(0),"
     "      entries: [{ binding: 0,"
     "                  resource: { buffer: slots[ubslot] } }] }); },"
     "  texture(slot, w, h) {"
     "    const GT = globalThis.GPUTextureUsage"
     "             || { TEXTURE_BINDING: 4, COPY_DST: 2 };"
     "    slots[slot] = st.dev.createTexture({"
     "      size: [w, h], format: 'rgba8unorm',"
     "      usage: GT.TEXTURE_BINDING | GT.COPY_DST }); },"
     "  texData(slot, base, w, h) {"
     "    st.q.writeTexture({ texture: slots[slot] },"
     "      new Uint8Array(memory.buffer, base, w * h * 4),"
     "      { bytesPerRow: w * 4 }, [w, h]); },"
     "  sampler(slot) {"
     "    slots[slot] = st.dev.createSampler({"
     "      magFilter: 'linear', minFilter: 'linear' }); },"
     "  texgroup(slot, pslot, ubslot, sslot, tslot) {"
     "    const entries = [];"
     "    if (ubslot >= 0)"
     "      entries.push({ binding: 0,"
     "                     resource: { buffer: slots[ubslot] } });"
     "    entries.push({ binding: entries.length,"
     "                   resource: slots[sslot] });"
     "    entries.push({ binding: entries.length,"
     "                   resource: slots[tslot].createView() });"
     "    slots[slot] = st.dev.createBindGroup({"
     "      layout: slots[pslot].getBindGroupLayout(0), entries }); },"
     "  bundle(slot, base, count) {"    ; draws only: no clear, no
     "    const dv = new DataView(memory.buffer);"  ; writes, no compute
     "    let p = base;"
     "    const end = base + count * 4;"
     "    const u = () => { const v = dv.getUint32(p, true); p += 4;"
     "                      return v; };"
     "    const be = st.dev.createRenderBundleEncoder({"
     "      colorFormats: [st.fmt],"
     "      depthStencilFormat: 'depth24plus' });"
     "    let pipeline = null, vbuf = null, vbuf2 = null;"
     "    let ibuf = null, group = null;"
     "    const ready = () => {"
     "      be.setPipeline(pipeline);"
     "      if (group) be.setBindGroup(0, group);"
     "      be.setVertexBuffer(0, vbuf);"
     "      if (vbuf2) be.setVertexBuffer(1, vbuf2); };"
     "    while (p < end) {"
     "      switch (u()) {"
     "        case 2: pipeline = slots[u()]; break;"
     "        case 3: vbuf = slots[u()]; break;"
     "        case 6: group = slots[u()]; break;"
     "        case 7: ibuf = slots[u()]; break;"
     "        case 10: vbuf2 = slots[u()]; break;"
     "        case 5: ready(); be.draw(u()); break;"
     "        case 8: ready(); be.setIndexBuffer(ibuf, 'uint16');"
     "                be.drawIndexed(u()); break;"
     "        case 11: ready(); { const v = u(); be.draw(v, u()); }"
     "                 break;"
     "        default: throw new Error('bundle: draw commands only');"
     "      }"
     "    }"
     "    slots[slot] = be.finish(); },"
     "  compute(slot, code) {"
     "    slots[slot] = st.dev.createComputePipeline({"
     "      layout: 'auto',"
     "      compute: { module: st.dev.createShaderModule({ code }),"
     "                 entryPoint: 'cs' } }); },"
     "  computeGroup(slot, pslot, sslot, uslot) {"
     "    slots[slot] = st.dev.createBindGroup({"
     "      layout: slots[pslot].getBindGroupLayout(0),"
     "      entries: [{ binding: 0,"
     "                  resource: { buffer: slots[sslot] } },"
     "                { binding: 1,"
     "                  resource: { buffer: slots[uslot] } }] }); },"
     "  hzbInit(slot, w, h) {"
     "    const GT = globalThis.GPUTextureUsage"
     "             || { TEXTURE_BINDING: 4, STORAGE_BINDING: 8 };"
     "    let levels = 1, m = Math.max(w, h);"
     "    while (m > 1) { m >>= 1; levels++; }"
     "    const tex = st.dev.createTexture({"
     "      size: [w, h], format: 'r32float', mipLevelCount: levels,"
     "      usage: (GT.TEXTURE_BINDING || 4) | (GT.STORAGE_BINDING || 8) });"
     "    const view = (l) => tex.createView({ baseMipLevel: l,"
     "                                         mipLevelCount: 1 });"
     "    const copy = st.dev.createComputePipeline({ layout: 'auto',"
     "      compute: { entryPoint: 'cs', module: st.dev.createShaderModule({ code:"
     "        '@group(0) @binding(0) var src: texture_depth_2d;' +"
     "        '@group(0) @binding(1) var dst: texture_storage_2d<r32float, write>;' +"
     "        '@compute @workgroup_size(8,8)' +"
     "        'fn cs(@builtin(global_invocation_id) g: vec3u) {' +"
     "        '  let d = textureDimensions(dst);' +"
     "        '  if (g.x >= d.x || g.y >= d.y) { return; }' +"
     "        '  textureStore(dst, vec2i(g.xy),' +"
     "        '    vec4f(textureLoad(src, vec2i(g.xy), 0), 0, 0, 0)); }' }) } });"
     "    const red = st.dev.createComputePipeline({ layout: 'auto',"
     "      compute: { entryPoint: 'cs', module: st.dev.createShaderModule({ code:"
     "        '@group(0) @binding(0) var src: texture_2d<f32>;' +"
     "        '@group(0) @binding(1) var dst: texture_storage_2d<r32float, write>;' +"
     "        '@compute @workgroup_size(8,8)' +"
     "        'fn cs(@builtin(global_invocation_id) g: vec3u) {' +"
     "        '  let d = textureDimensions(dst);' +"
     "        '  if (g.x >= d.x || g.y >= d.y) { return; }' +"
     "        '  let sd = vec2i(textureDimensions(src)) - vec2i(1);' +"
     "        '  let c = vec2i(g.xy) * 2;' +"
     "        '  let a = textureLoad(src, min(c, sd), 0).x;' +"
     "        '  let b = textureLoad(src, min(c + vec2i(1,0), sd), 0).x;' +"
     "        '  let e = textureLoad(src, min(c + vec2i(0,1), sd), 0).x;' +"
     "        '  let f = textureLoad(src, min(c + vec2i(1,1), sd), 0).x;' +"
     "        '  textureStore(dst, vec2i(g.xy),' +"
     "        '    vec4f(max(max(a,b), max(e,f)), 0, 0, 0)); }' }) } });"
     "    const groups = [st.dev.createBindGroup({"
     "      layout: copy.getBindGroupLayout(0),"
     "      entries: [{ binding: 0, resource: st.depth.createView() },"
     "                { binding: 1, resource: view(0) }] })];"
     "    for (let l = 1; l < levels; l++)"
     "      groups.push(st.dev.createBindGroup({"
     "        layout: red.getBindGroupLayout(0),"
     "        entries: [{ binding: 0, resource: view(l - 1) },"
     "                  { binding: 1, resource: view(l) }] }));"
     "    st.hzb = { tex, copy, red, groups, w, h, levels };"
     "    slots[slot] = tex; },"
     "  computeGroupX(slot, pslot, list) {"
     "    slots[slot] = st.dev.createBindGroup({"
     "      layout: slots[pslot].getBindGroupLayout(0),"
     "      entries: String(list).split(',').map((sp, i) =>"
     "        sp[0] === 't'"
     "          ? ({ binding: i,"
     "               resource: slots[Number(sp.slice(1))].createView() })"
     "          : ({ binding: i,"
     "               resource: { buffer: slots[Number(sp)] } })) }); },"
     "  computeGroupN(slot, pslot, list) {"
     "    slots[slot] = st.dev.createBindGroup({"
     "      layout: slots[pslot].getBindGroupLayout(0),"
     "      entries: String(list).split(',').map((s, i) =>"
     "        ({ binding: i,"
     "           resource: { buffer: slots[Number(s)] } })) }); },"
     "  gpuTimer() {"
     "    if (!st.ts) return 0;"
     "    const GB = globalThis.GPUBufferUsage"
     "             || { QUERY_RESOLVE: 512, COPY_SRC: 4,"
     "                  COPY_DST: 8, MAP_READ: 1 };"
     "    st.tq = st.dev.createQuerySet({ type: 'timestamp', count: 2 });"
     "    st.tqResolve = st.dev.createBuffer({"
     "      size: 16, usage: GB.QUERY_RESOLVE | GB.COPY_SRC });"
     "    st.tqRead = st.dev.createBuffer({"
     "      size: 16, usage: GB.COPY_DST | GB.MAP_READ });"
     "    st.tqBusy = false; st.tqMs = -1;"
     "    return 1; },"
     "  gpuMs() { return st.tqMs === undefined ? -1 : st.tqMs; },"
     "  replay(base, count) {"
     "    const dv = new DataView(memory.buffer);"
     "    let p = base;"
     "    const u = () => { const v = dv.getUint32(p, true); p += 4; return v; };"
     "    const f = () => { const v = dv.getFloat32(p, true); p += 4; return v; };"
     "    const enc = st.dev.createCommandEncoder();"
     "    let clear = { r: 0, g: 0, b: 0, a: 1 };"
     "    let pipeline = null, vbuf = null, vbuf2 = null, ibuf = null;"
     "    let group = null, pass = null, loadMode = 'clear';"
     "    const open = () => {"
     "      if (!pass) pass = enc.beginRenderPass({"
     "        colorAttachments: [{"
     "          view: st.ctx.getCurrentTexture().createView(),"
     "          loadOp: loadMode, clearValue: clear, storeOp: 'store' }],"
     "        depthStencilAttachment: {"
     "          view: st.depth.createView(),"
     "          depthClearValue: 1.0,"
     "          depthLoadOp: loadMode, depthStoreOp: 'store' },"
     "        timestampWrites: (st.tq && loadMode === 'clear') ? {"
     "          querySet: st.tq,"
     "          beginningOfPassWriteIndex: 0,"
     "          endOfPassWriteIndex: 1 } : undefined }); };"
     "    const ready = () => {"
     "      open(); pass.setPipeline(pipeline);"
     "      if (group) pass.setBindGroup(0, group);"
     "      pass.setVertexBuffer(0, vbuf);"
     "      if (vbuf2) pass.setVertexBuffer(1, vbuf2); };"
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
     "        case 9: {"                 ; a compute step: its own pass,
     "          const cpl = slots[u()];" ; legal only OUTSIDE the render
     "          const cg = slots[u()];"  ; pass (put dispatches first)
     "          const n = u();"
     "          const cp = enc.beginComputePass();"
     "          cp.setPipeline(cpl); cp.setBindGroup(0, cg);"
     "          cp.dispatchWorkgroups(n); cp.end(); break; }"
     "        case 10: vbuf2 = slots[u()]; break;"
     "        case 11: ready(); { const v = u(); pass.draw(v, u()); }"
     "                 break;"
     "        case 12: open(); pass.executeBundles([slots[u()]]);"
     "                 break;"
     "        case 13: ready(); pass.setIndexBuffer(ibuf, 'uint16');"
     "                 { const b = slots[u()];"
     "                   pass.drawIndexedIndirect(b, u()); } break;"
     "        case 14: ready(); { const b = slots[u()];"
     "                   pass.drawIndirect(b, u()); } break;"
     "        case 15: if (pass) { pass.end(); pass = null; }"
     "                 loadMode = 'load'; break;"
     "        case 16: {"
     "          const hz = st.hzb;"
     "          const cp = enc.beginComputePass();"
     "          cp.setPipeline(hz.copy); cp.setBindGroup(0, hz.groups[0]);"
     "          cp.dispatchWorkgroups(Math.ceil(hz.w / 8),"
     "                                Math.ceil(hz.h / 8));"
     "          let lw = hz.w, lh = hz.h;"
     "          for (let l = 1; l < hz.levels; l++) {"
     "            lw = Math.max(1, lw >> 1); lh = Math.max(1, lh >> 1);"
     "            cp.setPipeline(hz.red); cp.setBindGroup(0, hz.groups[l]);"
     "            cp.dispatchWorkgroups(Math.ceil(lw / 8),"
     "                                  Math.ceil(lh / 8));"
     "          }"
     "          cp.end(); break; }"
     "      }"
     "    }"
     "    open();"                       ; a clear-only frame still clears
     "    pass.end();"
     "    if (st.tq && !st.tqBusy) {"
     "      enc.resolveQuerySet(st.tq, 0, 2, st.tqResolve, 0);"
     "      enc.copyBufferToBuffer(st.tqResolve, 0, st.tqRead, 0, 16);"
     "    }"
     "    st.q.submit([enc.finish()]);"
     "    if (st.tq && !st.tqBusy) {"
     "      st.tqBusy = true;"
     "      st.tqRead.mapAsync(1).then(() => {"     ; GPUMapMode.READ
     "        const ts = new BigInt64Array(st.tqRead.getMappedRange());"
     "        st.tqMs = Number(ts[1] - ts[0]) / 1e6;"
     "        st.tqRead.unmap();"
     "        st.tqBusy = false; });"
     "    } } }; };"))

  ;; GPU frame time (needs the timestamp-query feature; ask AFTER
  ;; attach): the render pass stamps its beginning and end, results
  ;; resolve and map back a few frames behind.  gpu-gpu-timer!
  ;; answers #f where the adapter lacks the feature -- hide the
  ;; readout then; gpu-gpu-ms is -1.0 until the first result
  (define (gpu-gpu-timer!)
    (= 1 (js->number (js-method $gpu "gpuTimer"))))
  (define (gpu-gpu-ms)
    (let ((v (js->number (js-method $gpu "gpuMs"))))
      (if (flonum? v) v (exact->inexact v))))

  ;; the device handshake is asynchronous: k runs when the canvas is
  ;; configured and resources may be created
  ;;
  ;; A new device holds nothing a record was made for: the attach ends
  ;; the stream and starts a new era, so no stamp taken before it holds.
  (define (gpu-attach! canvas k)
    (set! $gpu-seg #f)
    (set! $gpu-cut #f)
    (set! $gpu-era (list 'era))
    (js-eval $gpu-src)
    (set! $gpu (js-call (js-get (js-global) "__goeteia_gpu") (js-undefined)
                        canvas (js-get (js-global) "__goeteia_mem")))
    (js-method $gpu "attach" k))

  ;; a render pipeline from one WGSL module (entry points vs / fs)
  ;; over one interleaved vertex buffer: stride in bytes, fmts a
  ;; comma-joined GPUVertexFormat list bound to locations 0,1,...
  (define (gpu-pipeline! slot wgsl stride fmts)
    (js-method $gpu "pipeline" slot wgsl stride fmts))
  ;; two vertex buffers: slot 0 steps per vertex, slot 1 per
  ;; instance; locations number straight through both
  (define (gpu-pipeline2! slot wgsl vstride vfmts istride ifmts)
    (js-method $gpu "pipeline2" slot wgsl vstride vfmts istride ifmts))
  ;; the same, with src-over alpha blending and depth writes off --
  ;; the translucent-pass pipeline
  (define (gpu-pipeline2-blend! slot wgsl vstride vfmts istride ifmts)
    (js-method $gpu "pipeline2b" slot wgsl vstride vfmts istride ifmts 1))
  ;; a compute pipeline from one WGSL module (entry point cs)
  (define (gpu-compute! slot wgsl)
    (js-method $gpu "compute" slot wgsl))
  ;; its bind group: binding 0 a storage buffer, binding 1 uniforms
  (define (gpu-compute-group! slot pslot sslot uslot)
    (js-method $gpu "computeGroup" slot pslot sslot uslot))
  (define (gpu-buffer! slot bytes)
    (js-method $gpu "buffer" slot bytes 0))
  (define (gpu-index! slot bytes)       ; u16 indices
    (js-method $gpu "buffer" slot bytes 1))
  ;; one uniform buffer per pipeline: the WGSL declares
  ;; @group(0) @binding(0) var<uniform> ... and the whole struct
  ;; rides one gpu-buffer-data! per frame
  (define (gpu-uniforms! slot bytes)
    (js-method $gpu "buffer" slot bytes 2))
  ;; a storage buffer that doubles as a vertex stream: compute
  ;; writes it, the render pass reads it back as attributes
  (define (gpu-storage! slot bytes)
    (js-method $gpu "buffer" slot bytes 3))
  ;; an indirect-argument buffer: compute writes the draw call's own
  ;; arguments (it is also storage), the render pass draws from it
  (define (gpu-indirect! slot bytes)
    (js-method $gpu "buffer" slot bytes 4))
  ;; a compute bind group over any buffer list: "3,5,6,4" binds
  ;; slots 3,5,6,4 at bindings 0..3 (storage or uniform alike --
  ;; the auto layout reads the WGSL)
  (define (gpu-compute-group*! slot pslot buffers)
    (js-method $gpu "computeGroupN" slot pslot buffers))
  ;; an rgba8 texture, filled straight from staging bytes
  (define (gpu-texture! slot w h)
    (js-method $gpu "texture" slot w h))
  (define (gpu-texture-data! slot base w h)
    (js-method $gpu "texData" slot base w h))
  (define (gpu-sampler! slot)
    (js-method $gpu "sampler" slot))
  ;; the textured bind group, in the order (gfx wgsl) declares its
  ;; bindings: the uniform struct at 0 (pass -1 when the shader has
  ;; no scalar uniforms), then sampler, then texture view
  (define (gpu-texgroup! slot pslot ubslot sslot tslot)
    (js-method $gpu "texgroup" slot pslot ubslot sslot tslot))
  (define (gpu-bindgroup! slot pslot ubslot)
    (js-method $gpu "bindgroup" slot pslot ubslot))

  ;; ---- the encoder: words into the staging memory, gl-style ----
  ;; The words go from $gpu-base up; $gpu-limit, when set, is the first
  ;; byte they may not reach.  A word that does not fit puts the cursor
  ;; back where its command began ($gpu-op, recorded by $gpu-op! before
  ;; the command's first word) and raises, so the region never holds
  ;; part of a command: a flush after the error replays whole commands
  ;; only, and none of the one that did not fit.  The error names where
  ;; that word would have gone.
  (define $gpu-base 0)
  (define $gpu-p 0)
  (define $gpu-limit #f)
  (define $gpu-op 0)

  ;; ---- the stream's own history ----
  ;; A library that keeps a record about what the GPU holds -- what an
  ;; instance buffer was filled with, whether a pyramid was reduced --
  ;; writes it when it ENCODES the command that makes it so, but the
  ;; command takes effect only when gpu-flush! REPLAYS it.  Words can be
  ;; encoded and never replayed (gpu-begin! drops what was not flushed,
  ;; gpu-bundle! turns them into a bundle, gpu-region!, a full region
  ;; and gpu-attach! cut the stream off, a replay can raise part way),
  ;; and a stream can be replayed more than once.  So a record carries
  ;; a stamp, (gpu-stamp), taken right after its words, the scheme
  ;; (gfx gl) uses, and is believed only while the stamp says so.
  ;;
  ;; A STREAM runs from one gpu-begin! to the next.  A SEGMENT runs from
  ;; the gpu-begin!, or from a completed flush, to the next completed
  ;; flush, gpu-begin! (gpu-bundle! ends with one) or stale event; each
  ;; segment has its own cell, and the cell is the stamp.  The encoder
  ;; is STALE from a gpu-region!, a full region, a gpu-attach! or a
  ;; replay that raises, until the next gpu-begin!, and before the
  ;; first one; while it is stale there is no current cell and
  ;; (gpu-stamp) is #f, so nothing written then is believed.
  ;;
  ;; A cell is marked replayed by a completed flush that ran it: as the
  ;; current cell, or, by a flush while stale, as the cell the stale
  ;; event cut off ($gpu-cut) -- whole commands from the stream's own
  ;; start, since a command that does not fit is rolled back ($gpu-op!,
  ;; $gpu-word!).  A flush from a base that gpu-region! moved without a
  ;; gpu-begin! may start inside a command, so it begins a new era, and
  ;; no cell made before it holds; so does gpu-attach!, which makes a
  ;; new device that holds nothing a record was made for.  Bundled words
  ;; are never replayed by a flush, so their cell is never marked.
  ;;
  ;; Two kinds of operation come out of one replay, and they are not
  ;; ordered as the stream is: an upload is a queue write made at once,
  ;; while the passes are recorded and submitted together after the
  ;; loop, so every queue write of a flush lands before every pass of
  ;; it.  Hence two predicates.  gpu-stamp-holds? -- the current
  ;; segment or a replayed one -- is for what a queue write put in a
  ;; buffer that only one staging range, written only by the record's
  ;; own site, ever fills.  gpu-stamp-replayed? -- a completed flush ran
  ;; it -- is for what a pass produced, which nothing may rely on until
  ;; a flush has run the pass.
  ;;
  ;; These variables change only as the transitions below say:
  ;;   $gpu-seg    the current segment's cell, or #f while stale
  ;;   $gpu-cut    the cell a stale event cut off, until the next
  ;;               gpu-begin! or gpu-attach!
  ;;   $gpu-era    replaced by a flush from a moved base and by
  ;;               gpu-attach!
  ;;   $gpu-moved  gpu-region! changed $gpu-base since the last
  ;;               gpu-begin!
  ;; A site that changes its record, or the state its check reads,
  ;; before its words are encoded stores #f in the record first.
  (define-record-type ($gpu-cell $make-gpu-cell $gpu-cell?)
    (fields (mutable replayed $gpu-cell-replayed? $gpu-cell-replayed!)
            (immutable stream $gpu-cell-stream)
            (immutable era $gpu-cell-era)))
  (define $gpu-seg #f)
  (define $gpu-cut #f)
  (define $gpu-era (list 'era))
  (define $gpu-moved #f)
  (define ($gpu-new-cell stream) ($make-gpu-cell #f stream $gpu-era))
  ;; the one stale transition of gpu-region! and a full region: cut the
  ;; current cell off.  gpu-attach! clears both instead (it does not
  ;; cut: a flush after it replays on another device)
  (define ($gpu-stale!)
    (when $gpu-seg
      (set! $gpu-cut $gpu-seg)
      (set! $gpu-seg #f)))
  (define (gpu-stamp) $gpu-seg)
  (define (gpu-stamp-holds? s)
    (and ($gpu-cell? s)
         (eq? ($gpu-cell-era s) $gpu-era)
         (or (eq? s $gpu-seg) ($gpu-cell-replayed? s))))
  (define (gpu-stamp-replayed? s)
    (and ($gpu-cell? s)
         (eq? ($gpu-cell-era s) $gpu-era)
         ($gpu-cell-replayed? s)))

  (define (gpu-region! base . limit)
    ($gpu-stale!)
    (unless (eqv? base $gpu-base)
      (set! $gpu-moved #t))
    (set! $gpu-base base)
    (set! $gpu-limit (and (pair? limit) (car limit)))
    (when (and $gpu-limit (< $gpu-limit $gpu-base))
      (error 'gpu-region! "limit precedes command base" $gpu-limit)))
  (define (gpu-begin!)
    (set! $gpu-p $gpu-base)
    (set! $gpu-seg ($gpu-new-cell (list 'stream)))
    (set! $gpu-cut #f)
    (set! $gpu-moved #f))
  (define (gpu-pos) $gpu-p)
  (define ($gpu-word!)
    (when (and $gpu-limit (> (+ $gpu-p 4) $gpu-limit))
      (let ((at $gpu-p))
        (set! $gpu-p $gpu-op)
        ($gpu-stale!)
        (error 'gpu-region! "command region overflow" at))))
  (define ($gpu-u! v)
    ($gpu-word!)
    (%mem-i32-set! $gpu-p v)
    (set! $gpu-p (+ $gpu-p 4)))
  (define ($gpu-f! v)
    ($gpu-word!)
    (%mem-f32-set! $gpu-p (if (flonum? v) v (exact->inexact v)))
    (set! $gpu-p (+ $gpu-p 4)))
  ;; every command's first word: the command starts here, recorded
  ;; BEFORE the word is written, so a first word that does not fit
  ;; rolls back to its own start and not to the previous command's
  (define ($gpu-op! v) (set! $gpu-op $gpu-p) ($gpu-u! v))
  ;; the words encoded since gpu-begin!, as the replayer counts them
  (define ($gpu-count) (quotient (- $gpu-p $gpu-base) 4))

  (define (gpu-clear! r g b a)
    ($gpu-op! 1) ($gpu-f! r) ($gpu-f! g) ($gpu-f! b) ($gpu-f! a))
  (define (gpu-use-pipeline! slot) ($gpu-op! 2) ($gpu-u! slot))
  (define (gpu-bind-vbuf! slot) ($gpu-op! 3) ($gpu-u! slot))
  (define (gpu-buffer-data! slot base bytes)
    ($gpu-op! 4) ($gpu-u! slot) ($gpu-u! base) ($gpu-u! bytes))
  (define (gpu-draw! verts) ($gpu-op! 5) ($gpu-u! verts))
  (define (gpu-set-group! slot) ($gpu-op! 6) ($gpu-u! slot))
  (define (gpu-bind-ibuf! slot) ($gpu-op! 7) ($gpu-u! slot))
  (define (gpu-draw-indexed! count) ($gpu-op! 8) ($gpu-u! count))
  ;; one compute step, its own pass: encode dispatches BEFORE the
  ;; frame's draws -- a render pass cannot be interrupted
  (define (gpu-dispatch! pslot gslot groups)
    ($gpu-op! 9) ($gpu-u! pslot) ($gpu-u! gslot) ($gpu-u! groups))
  (define (gpu-bind-vbuf2! slot) ($gpu-op! 10) ($gpu-u! slot))
  (define (gpu-draw-instanced! verts insts)
    ($gpu-op! 11) ($gpu-u! verts) ($gpu-u! insts))
  ;; occlusion: gpu-hzb-init! builds the depth pyramid resources
  ;; once; per frame, gpu-end-pass! closes the occluder pass (later
  ;; draws load instead of clear), gpu-hzb! reduces the depth buffer
  ;; into the pyramid, and a cull kernel bound via
  ;; gpu-compute-groupx! with a t-prefixed slot samples it
  (define (gpu-hzb-init! slot w h)
    (js-method $gpu "hzbInit" slot w h))
  (define (gpu-end-pass!) ($gpu-op! 15))
  (define (gpu-hzb!) ($gpu-op! 16))
  ;; like gpu-compute-group*! but entries may be textures: "3,4,t7"
  ;; binds buffers 3,4 and texture 7's full view
  (define (gpu-compute-groupx! slot pslot spec)
    (js-method $gpu "computeGroupX" slot pslot spec))

  ;; the GPU-driven draw: the argument buffer (gpu-indirect!) holds
  ;; [indexCount instanceCount firstIndex baseVertex firstInstance],
  ;; written by a compute pass -- a cull that never touches the CPU
  (define (gpu-draw-indexed-indirect! slot offset)
    ($gpu-op! 13) ($gpu-u! slot) ($gpu-u! offset))
  (define (gpu-draw-indirect! slot offset)
    ($gpu-op! 14) ($gpu-u! slot) ($gpu-u! offset))

  ;; freeze the commands encoded since gpu-begin! into a render
  ;; bundle -- draws and their state only.  Recorded once, a whole
  ;; static scene replays from inside the browser with no decode at
  ;; all: the frame becomes clear + uniforms + gpu-execute!
  ;; For the records it is a drop: the bundled words are never replayed
  ;; by a flush, and the gpu-begin! after it ends their stream.  A
  ;; bundle call that raises leaves the encoder as it was.
  (define (gpu-bundle! slot)
    (js-method $gpu "bundle" slot $gpu-base ($gpu-count))
    (gpu-begin!))
  (define (gpu-execute! slot) ($gpu-op! 12) ($gpu-u! slot))

  ;; The transitions of a flush.  With a current cell c: c stops being
  ;; current before the bridge call and is the cut-off cell while it
  ;; runs, so a replay that raises leaves the encoder stale with c cut
  ;; off; after it returns, c is marked replayed and a new segment of the
  ;; same stream begins.  While stale: from a moved base, a new era (the
  ;; words may start inside a command); otherwise the cut-off cell is
  ;; marked once the replay returns.
  (define (gpu-flush!)
    (let ((c $gpu-seg))
      (cond
       (c
        (set! $gpu-seg #f)
        (set! $gpu-cut c)
        (let ((r (js-method $gpu "replay" $gpu-base ($gpu-count))))
          ($gpu-cell-replayed! c #t)
          (set! $gpu-cut #f)
          (set! $gpu-seg ($gpu-new-cell ($gpu-cell-stream c)))
          r))
       ($gpu-moved
        (set! $gpu-era (list 'era))
        (set! $gpu-cut #f)
        (js-method $gpu "replay" $gpu-base ($gpu-count)))
       (else
        (let ((r (js-method $gpu "replay" $gpu-base ($gpu-count))))
          (when $gpu-cut
            ($gpu-cell-replayed! $gpu-cut #t))
          r))))))
