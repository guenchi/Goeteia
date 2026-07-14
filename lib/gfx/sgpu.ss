;; The sgl template on the WebGPU backend -- the declarative scene,
;; GPU-culled.  Same walker, same signal holes, same transform
;; chains; the differences are all downstream: every mesh joins a
;; geometry group (instancing is the only path -- WebGPU has no
;; cheap per-draw uniforms, so a "single" is a group of one), each
;; group's instances live in a storage buffer as matrix + color +
;; bounding sphere, a compute kernel culls them against the frustum
;; and compacts survivors straight into the render pass's instance
;; stream, and one drawIndexedIndirect per group draws exactly the
;; visible count.  The CPU recomposes only matrices whose signals
;; moved (the same generation scheme (gfx scene) uses) and never
;; looks at an instance again.
;;
;;   (define sc (sgl-gpu (camera ...) (light ...)
;;                       (group ... (mesh ...)) ...))
;;   (gpu-attach! canvas (lambda ()
;;     (sgpu-init! sc)
;;     (fx-ticks! (lambda (t dt)
;;       (gpu-begin!) (gpu-clear! ...)
;;       (sgpu-draw! sc) (gpu-flush!)))))
;;
;; Materials: lit solid color, (texture slot), and translucency --
;; a group any of whose instances has colour alpha below one draws
;; last on a src-over blend pipeline with depth writes off (its
;; instances aren't back-to-front sorted, so overlapping glass of
;; ONE group is order-dependent; separate panes are exact).
;; Grouping keys on geometry AND texture.  Not here yet (the GL
;; backend has them): PBR probes, lod containers, static welding,
;; and the HZB occlusion the raw gpu-cull example wires by hand.
;;
;; Copyright (c) 2026 guenchi. MIT license; see LICENSE.
(library (gfx sgpu)
  (export sgl-gpu $sgpu-build sgpu-init! sgpu-draw! sgpu-scene?
          sgpu-occlusion!)
  (import (rnrs) (web js) (gfx gpu) (gfx fx) (gfx mat) (gfx mesh)
          (web reactive))

  ;; ---- the template macro: identical walker to (gfx scene) ----
  (define-syntax sgl-gpu
    (lambda (x)
      (syntax-case x ()
        ((_ . forms)
         (let ((thunks '()) (nd 0))
           (letrec
               ((unq?
                 (lambda (t)
                   (and (pair? t) (eq? (car t) 'unquote)
                        (pair? (cdr t)) (null? (cddr t)))))
                (add-thunk!
                 (lambda (e)
                   (set! thunks (cons (list 'lambda '() e) thunks))
                   (set! nd (+ nd 1))
                   (cons '$sgpu-d (- nd 1))))
                (walk-attr
                 (lambda (a)
                   (if (and (pair? (cdr a)) (unq? (cadr a)) (null? (cddr a)))
                       (list (car a) (add-thunk! (cadr (cadr a))))
                       a)))
                (walk-form
                 (lambda (f)
                   (let* ((tag (car f)) (rest (cdr f))
                          (attrs? (and (pair? rest) (pair? (car rest))
                                       (eq? (car (car rest)) '@)))
                          (attrs (if attrs?
                                     (cons '@ (map walk-attr
                                                   (cdr (car rest))))
                                     '(@)))
                          (kids (if attrs? (cdr rest) rest)))
                     (if (eq? tag 'group)
                         (cons tag (cons attrs (map walk-form kids)))
                         (if attrs? (list tag attrs) f))))))
             (let ((anno (map walk-form forms)))
               (list '$sgpu-build (list 'quote anno)
                     (cons 'list (reverse thunks))))))))))

  (define ($sgpu-d? t) (and (pair? t) (eq? (car t) '$sgpu-d)))
  (define ($sgpu-fl v) (if (flonum? v) v (exact->inexact v)))

  ;; ---- runtime state ----
  ;; scene: #(cam light groups scratch envat ready?)
  ;; group: #(mesh nodes vslot islot srcslot dstslot argslot groupslot
  ;;          icount cap gens srcbase)
  ;; node:  #(f chain bc br)
  (define-record-type (sgpu-scene $make-sgpu sgpu-scene?)
    (fields (immutable cam $sg-cam)
            (immutable light $sg-light)
            (immutable groups $sg-groups)
            (mutable envat $sg-envat $sg-envat!)
            (mutable aspect $sg-aspect $sg-aspect!)
            (mutable ready $sg-ready $sg-ready!)))

  (define ($sgpu-set1! vec idx v ds gen)
    (if ($sgpu-d? v)
        (let ((th (list-ref ds (cdr v))))
          (effect (lambda ()
                    (vector-set! vec idx ($sgpu-fl (th)))
                    (when gen
                      (vector-set! vec gen
                                   (+ 1 (vector-ref vec gen)))))))
        (vector-set! vec idx ($sgpu-fl v))))
  (define ($sgpu-set3! vec idx vals)
    (vector-set! vec idx ($sgpu-fl (car vals)))
    (vector-set! vec (+ idx 1) ($sgpu-fl (cadr vals)))
    (vector-set! vec (+ idx 2) ($sgpu-fl (caddr vals))))

  (define ($sgpu-geometry spec ds)
    (if ($sgpu-d? spec)
        ((list-ref ds (cdr spec)))
        (case (car spec)
          ((plane) (mesh-plane (cadr spec) (caddr spec)))
          ((box) (mesh-box (cadr spec) (caddr spec) (cadddr spec)))
          ((sphere) (apply mesh-sphere (cdr spec)))
          ((cylinder) (apply mesh-cylinder (cdr spec)))
          ((torus) (apply mesh-torus (cdr spec)))
          (else (error 'sgl-gpu "unknown geometry" (car spec))))))

  (define ($sgpu-build forms ds)
    (let ((cam (vector 0.9 0.1 100.0 0.0 2.0 8.0 0.0 0.0 0.0))
          (light (vector 0.5 0.8 0.4 0.25))
          (cache (list '()))
          (meshes '()))
      (let walk ((forms forms) (chain '()))
        (for-each
         (lambda (f)
           (let* ((attrs? (and (pair? (cdr f)) (pair? (cadr f))
                               (eq? (car (cadr f)) '@)))
                  (attrs (if attrs? (cdr (cadr f)) '()))
                  (kids (if attrs? (cddr f) (cdr f))))
             (case (car f)
               ((camera)
                (for-each
                 (lambda (a)
                   (case (car a)
                     ((fov) ($sgpu-set1! cam 0 (cadr a) ds #f))
                     ((near) ($sgpu-set1! cam 1 (cadr a) ds #f))
                     ((far) ($sgpu-set1! cam 2 (cadr a) ds #f))
                     ((position) ($sgpu-set3! cam 3 (cdr a)))
                     ((look-at) ($sgpu-set3! cam 6 (cdr a)))
                     (else (error 'sgl-gpu "unknown camera attribute"
                                  (car a)))))
                 attrs))
               ((light)
                (for-each
                 (lambda (a)
                   (case (car a)
                     ((direction) ($sgpu-set3! light 0 (cdr a)))
                     ((ambient) ($sgpu-set1! light 3 (cadr a) ds #f))
                     (else (error 'sgl-gpu "unknown light attribute"
                                  (car a)))))
                 attrs))
               ((group)
                (let ((gf (vector 0.0 0.0 0.0 0.0 0.0 0.0 1.0 0)))
                  (for-each
                   (lambda (a)
                     (case (car a)
                       ((position) ($sgpu-set3! gf 0 (cdr a)))
                       ((rotation) ($sgpu-set3! gf 3 (cdr a)))
                       ((position-x) ($sgpu-set1! gf 0 (cadr a) ds 7))
                       ((position-y) ($sgpu-set1! gf 1 (cadr a) ds 7))
                       ((position-z) ($sgpu-set1! gf 2 (cadr a) ds 7))
                       ((rotation-x) ($sgpu-set1! gf 3 (cadr a) ds 7))
                       ((rotation-y) ($sgpu-set1! gf 4 (cadr a) ds 7))
                       ((rotation-z) ($sgpu-set1! gf 5 (cadr a) ds 7))
                       ((scale) ($sgpu-set1! gf 6 (cadr a) ds 7))
                       (else (error 'sgl-gpu "unknown group attribute"
                                    (car a)))))
                   attrs)
                  (walk kids (append chain (list gf)))))
               ((mesh)
                (let ((gspec #f)
                      (tex #f)
                      (f (vector 0.0 0.0 0.0 0.0 0.0 0.0 1.0
                                 0.8 0.8 0.8 1.0 0.0 0.5 0)))
                  (for-each
                   (lambda (a)
                     (case (car a)
                       ((geometry) (set! gspec (cadr a)))
                       ((texture)
                        (set! tex (if ($sgpu-d? (cadr a))
                                      ((list-ref ds (cdr (cadr a))))
                                      (cadr a))))
                       ((position) ($sgpu-set3! f 0 (cdr a)))
                       ((rotation) ($sgpu-set3! f 3 (cdr a)))
                       ((color) ($sgpu-set3! f 7 (cdr a))
                        (unless (null? (cdddr (cdr a)))
                          (vector-set! f 10
                                       ($sgpu-fl (car (cdddr (cdr a)))))))
                       ((position-x) ($sgpu-set1! f 0 (cadr a) ds 13))
                       ((position-y) ($sgpu-set1! f 1 (cadr a) ds 13))
                       ((position-z) ($sgpu-set1! f 2 (cadr a) ds 13))
                       ((rotation-x) ($sgpu-set1! f 3 (cadr a) ds 13))
                       ((rotation-y) ($sgpu-set1! f 4 (cadr a) ds 13))
                       ((rotation-z) ($sgpu-set1! f 5 (cadr a) ds 13))
                       ((scale) ($sgpu-set1! f 6 (cadr a) ds 13))
                       ((color-r) ($sgpu-set1! f 7 (cadr a) ds #f))
                       ((color-g) ($sgpu-set1! f 8 (cadr a) ds #f))
                       ((color-b) ($sgpu-set1! f 9 (cadr a) ds #f))
                       ((color-a) ($sgpu-set1! f 10 (cadr a) ds #f))
                       (else (error 'sgl-gpu "unknown mesh attribute"
                                    (car a)))))
                   attrs)
                  (unless gspec (error 'sgl-gpu "mesh needs a geometry"))
                  ;; the group key is geometry AND texture: same
                  ;; shape, same texture instances together
                  (set! meshes
                        (cons (cons (cons gspec tex)
                                    (vector f chain #f #f))
                              meshes))))
               (else (error 'sgl-gpu "unsupported tag on gpu backend"
                            (car f))))))
         forms))
      ;; group by (geometry . texture), building meshes once; an
      ;; injected (unquote) geometry stays its own group
      (let group ((ms (reverse meshes)) (groups '()))
        (if (pair? ms)
            (let* ((key (car (car ms)))
                   (nd (cdr (car ms)))
                   (hit (and (not ($sgpu-d? (car key)))
                             (assoc key groups))))
              (if hit
                  (begin (set-cdr! hit (cons nd (cdr hit)))
                         (group (cdr ms) groups))
                  (group (cdr ms) (cons (list key nd) groups))))
            ($make-sgpu
             cam light
             (map (lambda (g)
                    (let* ((key (car g))
                           (m ($sgpu-geometry (car key) ds))
                           (tex (cdr key))
                           (bounds (mesh-bounds m))
                           (nodes (reverse (cdr g))))
                      (for-each (lambda (nd)
                                  (vector-set! nd 2 (car bounds))
                                  (vector-set! nd 3 (cdr bounds)))
                                nodes)
                      ;; +texture slot (13), +tex render group (14),
                      ;; +translucent? (15): any node's alpha below 1
                      ;; sends the whole group to the blended pass
                      (vector m nodes 0 0 0 0 0 0
                              (mesh-index-count m)
                              (length nodes)
                              -1 0 0 tex 0
                              (let any ((ns nodes))
                                (and (pair? ns)
                                     (or (fl<? (vector-ref
                                                (vector-ref (car ns) 0)
                                                10)
                                               1.0)
                                         (any (cdr ns))))))))
                  (reverse groups))
             0 1.333 #f)))))

  ;; ---- gpu resources; call once inside gpu-attach!'s callback ----
  (define $sgpu-cull
    (string-append
     "struct Inst { m0 : vec4f, m1 : vec4f, m2 : vec4f, m3 : vec4f,\n"
     "              color : vec4f, sphere : vec4f, pad : vec4f,\n"
     "              pad2 : vec4f }\n"
     "struct Vis { m0 : vec4f, m1 : vec4f, m2 : vec4f, m3 : vec4f,\n"
     "             color : vec4f }\n"
     "struct Args { indexCount : u32, instanceCount : atomic<u32>,\n"
     "              firstIndex : u32, baseVertex : u32,\n"
     "              firstInstance : u32 }\n"
     "struct Env { vp : mat4x4f, planes : array<vec4f, 6>,\n"
     "             light : vec4f, ambient : vec4f,\n"
     "             p00 : f32, p11 : f32, sw : f32, sh : f32,\n"
     "             pA : f32, mode : u32, pd0 : u32, pd1 : u32 }\n"
     "@group(0) @binding(0) var<storage, read> src : array<Inst>;\n"
     "@group(0) @binding(1) var<storage, read_write> dst : array<Vis>;\n"
     "@group(0) @binding(2) var<storage, read_write> args : Args;\n"
     "@group(0) @binding(3) var<uniform> env : Env;\n"
     "@group(0) @binding(4) var hzb : texture_2d<f32>;\n"
     "@compute @workgroup_size(64)\n"
     "fn cs(@builtin(global_invocation_id) id : vec3u) {\n"
     "  let i = id.x;\n"
     "  if (i >= arrayLength(&src)) { return; }\n"
     "  let s = src[i];\n"
     "  for (var p = 0u; p < 6u; p++) {\n"
     "    if (dot(env.planes[p].xyz, s.sphere.xyz) + env.planes[p].w\n"
     "        < -s.sphere.w) { return; }\n"
     "  }\n"
     ;; occlusion: project the bounding sphere, sample the hi-Z pyramid
     ;; over its screen footprint; cull when its nearest depth is behind
     ;; everything already drawn there.  Mirrors examples/gpu-hzb.ss.
     "  if (env.mode == 1u) {\n"
     "    let clip = env.vp * vec4f(s.sphere.xyz, 1.0);\n"
     "    if (clip.w > s.sphere.w) {\n"
     "      let ndc = clip.xy / clip.w;\n"
     "      let rx = s.sphere.w * env.p00 / clip.w;\n"
     "      let ry = s.sphere.w * env.p11 / clip.w;\n"
     "      let px = max(rx * env.sw, ry * env.sh);\n"
     "      let mip = clamp(u32(ceil(log2(max(px, 1.0)))), 0u, 8u);\n"
     "      let dims = vec2f(textureDimensions(hzb, mip));\n"
     "      let uv = ndc * vec2f(0.5, -0.5) + vec2f(0.5, 0.5);\n"
     "      let lo = vec2i(clamp((uv - vec2f(rx * 0.5, ry * 0.5))\n"
     "                           * dims, vec2f(0.0), dims - 1.0));\n"
     "      let hi = vec2i(clamp((uv + vec2f(rx * 0.5, ry * 0.5))\n"
     "                           * dims, vec2f(0.0), dims - 1.0));\n"
     "      let d = max(max(textureLoad(hzb, lo, i32(mip)).x,\n"
     "                      textureLoad(hzb, vec2i(hi.x, lo.y),\n"
     "                                  i32(mip)).x),\n"
     "                  max(textureLoad(hzb, vec2i(lo.x, hi.y),\n"
     "                                  i32(mip)).x,\n"
     "                      textureLoad(hzb, hi, i32(mip)).x));\n"
     "      let sphereNear = clamp((clip.z + env.pA * s.sphere.w)\n"
     "                        / max(clip.w - s.sphere.w, 0.001),\n"
     "                        0.0, 1.0);\n"
     "      if (sphereNear > d) { return; }\n"
     "    }\n"
     "  }\n"
     "  let k = atomicAdd(&args.instanceCount, 1u);\n"
     "  dst[k] = Vis(s.m0, s.m1, s.m2, s.m3, s.color);\n"
     "}\n"))

  (define $sgpu-render
    (string-append
     "struct Env { vp : mat4x4f, planes : array<vec4f, 6>,\n"
     "             light : vec4f, ambient : vec4f,\n"
     "             p00 : f32, p11 : f32, sw : f32, sh : f32,\n"
     "             pA : f32, mode : u32, pd0 : u32, pd1 : u32 }\n"
     "@group(0) @binding(0) var<uniform> env : Env;\n"
     "struct VOut { @builtin(position) pos : vec4f,\n"
     "              @location(0) c : vec4f }\n"
     "@vertex fn vs(@location(0) p : vec3f, @location(1) n : vec3f,\n"
     "              @location(2) m0 : vec4f, @location(3) m1 : vec4f,\n"
     "              @location(4) m2 : vec4f, @location(5) m3 : vec4f,\n"
     "              @location(6) color : vec4f) -> VOut {\n"
     "  var o : VOut;\n"
     "  let m = mat4x4f(m0, m1, m2, m3);\n"
     "  o.pos = env.vp * (m * vec4f(p, 1.0));\n"
     "  let wn = normalize((m * vec4f(n, 0.0)).xyz);\n"
     "  let d = max(dot(wn, normalize(env.light.xyz)), 0.0);\n"
     "  let a = env.ambient.x;\n"
     "  o.c = vec4f(color.rgb * (a + d * (1.0 - a)), color.a);\n"
     "  return o;\n"
     "}\n"
     "@fragment fn fs(@location(0) c : vec4f) -> @location(0) vec4f {\n"
     "  return c;\n"
     "}\n"))

  ;; the textured variant: a uv vertex attribute (per-vertex stride
  ;; 32), a sampler + texture at bindings 1/2, colour multiplies the
  ;; sample.  Instance attributes shift up by one location
  (define $sgpu-render-tex
    (string-append
     "struct Env { vp : mat4x4f, planes : array<vec4f, 6>,\n"
     "             light : vec4f, ambient : vec4f,\n"
     "             p00 : f32, p11 : f32, sw : f32, sh : f32,\n"
     "             pA : f32, mode : u32, pd0 : u32, pd1 : u32 }\n"
     "@group(0) @binding(0) var<uniform> env : Env;\n"
     "@group(0) @binding(1) var samp : sampler;\n"
     "@group(0) @binding(2) var tex : texture_2d<f32>;\n"
     "struct VOut { @builtin(position) pos : vec4f,\n"
     "              @location(0) c : vec4f, @location(1) uv : vec2f }\n"
     "@vertex fn vs(@location(0) p : vec3f, @location(1) n : vec3f,\n"
     "              @location(2) uv : vec2f,\n"
     "              @location(3) m0 : vec4f, @location(4) m1 : vec4f,\n"
     "              @location(5) m2 : vec4f, @location(6) m3 : vec4f,\n"
     "              @location(7) color : vec4f) -> VOut {\n"
     "  var o : VOut;\n"
     "  let m = mat4x4f(m0, m1, m2, m3);\n"
     "  o.pos = env.vp * (m * vec4f(p, 1.0));\n"
     "  let wn = normalize((m * vec4f(n, 0.0)).xyz);\n"
     "  let d = max(dot(wn, normalize(env.light.xyz)), 0.0);\n"
     "  let a = env.ambient.x;\n"
     "  o.c = vec4f(color.rgb * (a + d * (1.0 - a)), color.a);\n"
     "  o.uv = uv;\n"
     "  return o;\n"
     "}\n"
     "@fragment fn fs(@location(0) c : vec4f, @location(1) uv : vec2f)\n"
     "    -> @location(0) vec4f {\n"
     "  return c * textureSample(tex, samp, uv);\n"
     "}\n"))

  ;; fixed slots: 0 env, 1 cull pipeline, 2 lit pipeline, 3 env bind
  ;; group, 4 textured pipeline, 5 shared sampler, 6/7 the blended
  ;; (lit/tex) pipelines; groups take 8 slots each from 8 up
  (define $inst-fmt
    "float32x4,float32x4,float32x4,float32x4,float32x4")

  ;; hi-Z occlusion state (module-level, like $sgpu-scratch): one depth
  ;; pyramid shared by the active scene.  Cull runs a frame behind the
  ;; pyramid -- mode stays 0 until the first gpu-hzb!, and while a
  ;; camera/scene is static last frame's pyramid is exact, so the
  ;; occluded set matches (occlusion that changes the picture is a bug).
  (define $sgpu-hzb-slot 250)           ; the pyramid resource slot
  (define $sgpu-hzb-w 0.0)
  (define $sgpu-hzb-h 0.0)
  (define $sgpu-hzb-built #f)
  (define $sgpu-occlusion #t)
  (define (sgpu-occlusion! on?) (set! $sgpu-occlusion (and on? #t)))

  (define (sgpu-init! sc canvas)
    (set! $sgpu-hzb-w ($sgpu-fl (js->number (js-get canvas "width"))))
    (set! $sgpu-hzb-h ($sgpu-fl (js->number (js-get canvas "height"))))
    (set! $sgpu-hzb-built #f)
    ($sg-aspect! sc (fl/ $sgpu-hzb-w $sgpu-hzb-h))
    (gpu-uniforms! 0 224)
    (gpu-compute! 1 $sgpu-cull)
    (gpu-hzb-init! $sgpu-hzb-slot $sgpu-hzb-w $sgpu-hzb-h)
    (gpu-pipeline2! 2 $sgpu-render 24 "float32x3,float32x3" 80 $inst-fmt)
    (gpu-bindgroup! 3 2 0)
    (gpu-pipeline2! 4 $sgpu-render-tex
                    32 "float32x3,float32x3,float32x2" 80 $inst-fmt)
    (gpu-sampler! 5)
    ;; the translucent-pass pipelines: src-over blend, depth writes
    ;; off.  A pipeline's 'auto layout is its own object, so the env
    ;; bind group must come from the pipeline it is used with -- slot
    ;; 8 is the blend-lit env group
    (gpu-pipeline2-blend! 6 $sgpu-render 24 "float32x3,float32x3"
                          80 $inst-fmt)
    (gpu-pipeline2-blend! 7 $sgpu-render-tex
                          32 "float32x3,float32x3,float32x2" 80 $inst-fmt)
    (gpu-bindgroup! 8 6 0)
    ($sg-envat! sc (fx-alloc! 224))
    (let init ((gs ($sg-groups sc)) (slot 9))
      (when (pair? gs)
        (let* ((g (car gs))
               (m (vector-ref g 0))
               (tex (vector-ref g 13))
               (cap (vector-ref g 9))
               (vbytes (if tex (mesh-vertex-bytes-uv m)
                           (mesh-vertex-bytes m)))
               (ibytes (mesh-index-bytes m))
               (vbase (fx-alloc! vbytes))
               (ibase (fx-alloc! ibytes))
               (srcbase (fx-alloc! (* cap 128)))
               (argbase (fx-alloc! 20)))
          (if tex (mesh-write-uv! m vbase ibase)
              (mesh-write! m vbase ibase))
          (gpu-buffer! slot vbytes)
          (gpu-index! (+ slot 1) ibytes)
          (gpu-storage! (+ slot 2) (* cap 128))     ; src instances
          (gpu-storage! (+ slot 3) (* cap 80))      ; visible
          (gpu-indirect! (+ slot 4) 20)
          ;; binding 4 of the cull is the hi-Z texture (t-prefixed)
          (gpu-compute-groupx! (+ slot 5)
                               1
                               (string-append
                                (number->string (+ slot 2)) ","
                                (number->string (+ slot 3)) ","
                                (number->string (+ slot 4)) ",0,t"
                                (number->string $sgpu-hzb-slot)))
          (vector-set! g 2 slot)
          (vector-set! g 3 (+ slot 1))
          (vector-set! g 4 (+ slot 2))
          (vector-set! g 5 (+ slot 3))
          (vector-set! g 6 (+ slot 4))
          (vector-set! g 7 (+ slot 5))
          ;; textured groups need a render bind group (env, sampler,
          ;; the group's texture) from the pipeline they actually
          ;; use -- the blend-tex pipeline 7 for a translucent group,
          ;; else the opaque tex pipeline 4; lit groups reuse a
          ;; shared env group (3 opaque, 8 blended)
          (when tex
            (gpu-texgroup! (+ slot 6) (if (vector-ref g 15) 7 4)
                           0 5 tex)
            (vector-set! g 14 (+ slot 6)))
          (vector-set! g 11 srcbase)
          (vector-set! g 12 argbase)
          (%mem-i32-set! argbase (vector-ref g 8))
          (%mem-i32-set! (+ argbase 4) 0)
          (%mem-i32-set! (+ argbase 8) 0)
          (%mem-i32-set! (+ argbase 12) 0)
          (%mem-i32-set! (+ argbase 16) 0)
          ;; geometry ships now, once
          (gpu-begin!)
          (gpu-buffer-data! slot vbase vbytes)
          (gpu-buffer-data! (+ slot 1) ibase ibytes)
          (gpu-flush!))
        (init (cdr gs) (+ slot 7))))
    ($sg-ready! sc #t))

  (define ($sgpu-gen nodes)
    (fold-left
     (lambda (a nd)
       (+ a (vector-ref (vector-ref nd 0) 13)
          (fold-left (lambda (b gf) (+ b (vector-ref gf 7)))
                     0 (vector-ref nd 1))))
     0 nodes))

  (define ($sgpu-trs! at f)
    (m4s-trs! at (vector-ref f 0) (vector-ref f 1) (vector-ref f 2)
              (vector-ref f 3) (vector-ref f 4) (vector-ref f 5)
              (vector-ref f 6)))

  ;; compose one node's model matrix + color + world sphere into its
  ;; 128-byte instance slot
  (define ($sgpu-inst! nd at scratch)
    (let* ((f (vector-ref nd 0))
           (chain (vector-ref nd 1))
           (n-ch (length chain)))
      (if (= n-ch 0)
          ($sgpu-trs! at f)
          (let ((sg scratch) (sa (+ scratch 64)) (sb (+ scratch 128)))
            ($sgpu-trs! sa f)
            (let fold ((gs (reverse chain)) (i 0) (acc sa))
              (when (pair? gs)
                ($sgpu-trs! sg (car gs))
                (let ((dst (if (= i (- n-ch 1))
                               at
                               (if (= acc sa) sb sa))))
                  (m4s-mul! dst sg acc)
                  (fold (cdr gs) (+ i 1) dst))))))
      (%mem-f32-set! (+ at 64) (vector-ref f 7))
      (%mem-f32-set! (+ at 68) (vector-ref f 8))
      (%mem-f32-set! (+ at 72) (vector-ref f 9))
      (%mem-f32-set! (+ at 76) (vector-ref f 10))
      ;; the world bounding sphere: transformed center, scaled radius
      (let* ((bc (vector-ref nd 2))
             (x (v3-x bc)) (y (v3-y bc)) (z (v3-z bc))
             (s (fold-left (lambda (a gf) (fl* a (vector-ref gf 6)))
                           (vector-ref f 6) chain)))
        (%mem-f32-set!
         (+ at 80)
         (fl+ (fl+ (fl* (%mem-f32-ref at) x)
                   (fl* (%mem-f32-ref (+ at 16)) y))
              (fl+ (fl* (%mem-f32-ref (+ at 32)) z)
                   (%mem-f32-ref (+ at 48)))))
        (%mem-f32-set!
         (+ at 84)
         (fl+ (fl+ (fl* (%mem-f32-ref (+ at 4)) x)
                   (fl* (%mem-f32-ref (+ at 20)) y))
              (fl+ (fl* (%mem-f32-ref (+ at 36)) z)
                   (%mem-f32-ref (+ at 52)))))
        (%mem-f32-set!
         (+ at 88)
         (fl+ (fl+ (fl* (%mem-f32-ref (+ at 8)) x)
                   (fl* (%mem-f32-ref (+ at 24)) y))
              (fl+ (fl* (%mem-f32-ref (+ at 40)) z)
                   (%mem-f32-ref (+ at 56)))))
        (%mem-f32-set! (+ at 92) (fl* s (vector-ref nd 3))))))

  (define $sgpu-scratch #f)

  (define (sgpu-draw! sc)
    (when ($sg-ready sc)
      (unless $sgpu-scratch (set! $sgpu-scratch (fx-alloc! 192)))
      (let* ((cam ($sg-cam sc))
             (light ($sg-light sc))
             (eye (v3 (vector-ref cam 3) (vector-ref cam 4)
                      (vector-ref cam 5)))
             (proj (let* ((f (fl/ 1.0 (fltan (fl/ (vector-ref cam 0)
                                                  2.0))))
                          (near (vector-ref cam 1))
                          (far (vector-ref cam 2))
                          (nf (fl/ 1.0 (fl- near far))))
                     ;; WebGPU depth range: z lands in [0, 1]
                     (vector (fl/ f ($sg-aspect sc))
                             0.0 0.0 0.0
                             0.0 f 0.0 0.0
                             0.0 0.0 (fl* far nf) -1.0
                             0.0 0.0 (fl* (fl* far near) nf) 0.0)))
             (vp (m4-mul proj
                         (m4-look-at eye
                                     (v3 (vector-ref cam 6)
                                         (vector-ref cam 7)
                                         (vector-ref cam 8))
                                     (v3 0.0 1.0 0.0))))
             (planes (m4-frustum-planes vp))
             (ld (v3-normalize (v3 (vector-ref light 0)
                                   (vector-ref light 1)
                                   (vector-ref light 2))))
             (ea ($sg-envat sc)))
        (m4s-write! ea vp)
        (let plane ((i 0))
          (when (< i 6)
            (let ((p (vector-ref planes i))
                  (at (+ ea 64 (* i 16))))
              (%mem-f32-set! at (vector-ref p 0))
              (%mem-f32-set! (+ at 4) (vector-ref p 1))
              (%mem-f32-set! (+ at 8) (vector-ref p 2))
              (%mem-f32-set! (+ at 12) (vector-ref p 3)))
            (plane (+ i 1))))
        (%mem-f32-set! (+ ea 160) (v3-x ld))
        (%mem-f32-set! (+ ea 164) (v3-y ld))
        (%mem-f32-set! (+ ea 168) (v3-z ld))
        (%mem-f32-set! (+ ea 172) 0.0)
        (%mem-f32-set! (+ ea 176) (vector-ref light 3))
        ;; projection params + occlusion mode for the hi-Z cull
        (%mem-f32-set! (+ ea 192) (vector-ref proj 0))   ; p00
        (%mem-f32-set! (+ ea 196) (vector-ref proj 5))   ; p11
        (%mem-f32-set! (+ ea 200) $sgpu-hzb-w)           ; sw
        (%mem-f32-set! (+ ea 204) $sgpu-hzb-h)           ; sh
        (%mem-f32-set! (+ ea 208) (vector-ref proj 10))  ; pA
        (%mem-i32-set! (+ ea 212)
                       (if (and $sgpu-occlusion $sgpu-hzb-built) 1 0))
        (%mem-i32-set! (+ ea 216) 0)
        (%mem-i32-set! (+ ea 220) 0)
        (gpu-buffer-data! 0 ea 224)
        ;; refresh dirty groups, reset args, dispatch culls
        (for-each
         (lambda (g)
           (let ((gen ($sgpu-gen (vector-ref g 1))))
             (unless (= gen (vector-ref g 10))
               (vector-set! g 10 gen)
               (let comp ((ns (vector-ref g 1)) (k 0))
                 (when (pair? ns)
                   ($sgpu-inst! (car ns)
                                (+ (vector-ref g 11) (* k 128))
                                $sgpu-scratch)
                   (comp (cdr ns) (+ k 1))))
               (gpu-buffer-data! (vector-ref g 4) (vector-ref g 11)
                                 (* (vector-ref g 9) 128))))
           ;; the group's own argument reset (writeBuffer reads
           ;; staging at flush, so each group keeps its own words)
           (gpu-buffer-data! (vector-ref g 6) (vector-ref g 12) 20)
           (gpu-dispatch! 1 (vector-ref g 7)
                          (quotient (+ (vector-ref g 9) 63) 64)))
         ($sg-groups sc))
        ;; the draws -- opaque groups first, then the translucent
        ;; ones on the blended pipelines (their instances aren't
        ;; back-to-front sorted yet, so overlapping glass of the
        ;; same group is order-dependent; non-overlapping is exact).
        ;; Textured groups ride the textured pipeline with their own
        ;; bind group, lit ones the shared
        (let ((draw
               (lambda (g lit-pl tex-pl env-grp)
                 (if (vector-ref g 13)
                     (begin (gpu-use-pipeline! tex-pl)
                            (gpu-set-group! (vector-ref g 14)))
                     (begin (gpu-use-pipeline! lit-pl)
                            (gpu-set-group! env-grp)))
                 (gpu-bind-vbuf! (vector-ref g 2))
                 (gpu-bind-vbuf2! (vector-ref g 5))
                 (gpu-bind-ibuf! (vector-ref g 3))
                 (gpu-draw-indexed-indirect! (vector-ref g 6) 0))))
          (for-each (lambda (g)
                      (unless (vector-ref g 15) (draw g 2 4 3)))
                    ($sg-groups sc))
          (for-each (lambda (g)
                      (when (vector-ref g 15) (draw g 6 7 8)))
                    ($sg-groups sc))
          ;; reduce this frame's depth into the hi-Z pyramid; next
          ;; frame's cull occludes against it (mode is 0 until it exists)
          (gpu-end-pass!)
          (gpu-hzb!)
          (set! $sgpu-hzb-built #t))))))
