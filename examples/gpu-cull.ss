;; GPU-driven culling: 100,000 boxes, and the CPU never looks at one.
;; A compute pass tests every instance's bounding sphere against the
;; frustum, compacts the survivors into the render pass's instance
;; stream with one atomicAdd, and writes the draw call's OWN argument
;; buffer -- gpu-draw-indexed-indirect! then draws exactly the
;; visible count.  Per frame the CPU contributes 176 bytes of
;; uniforms (vp + planes) and a 20-byte argument reset; everything
;; else lives and dies on the GPU.  Needs a WebGPU browser.
(import (rnrs) (web js) (web dom) (gfx fx) (gfx gpu) (gfx mat)
        (gfx mesh))

(define N 100000)
(define IBYTES (* N 32))                ; vec4 pos+radius, vec4 color
(define UBASE 4096)                     ; 176B uniforms
(define ABASE 4288)                     ; 20B indirect reset
(define GBASE 4352)                     ; box geometry
(define SBASE 65536)                    ; the instance field
(let ((need (- (+ SBASE IBYTES) (* 65536 (%mem-size)))))
  (when (> need 0)
    (%mem-grow (quotient (+ need 65535) 65536))))

;; the cull kernel: sphere vs six planes, survivors compact
(define CS
  (string-append
   "struct Inst { pos : vec4f, color : vec4f }\n"
   "struct Args { indexCount : u32, instanceCount : atomic<u32>,\n"
   "              firstIndex : u32, baseVertex : u32,\n"
   "              firstInstance : u32 }\n"
   "struct Env { vp : mat4x4f, planes : array<vec4f, 6>,\n"
   "             count : u32, p0 : u32, p1 : u32, p2 : u32 }\n"
   "@group(0) @binding(0) var<storage, read> src : array<Inst>;\n"
   "@group(0) @binding(1) var<storage, read_write> dst : array<Inst>;\n"
   "@group(0) @binding(2) var<storage, read_write> args : Args;\n"
   "@group(0) @binding(3) var<uniform> env : Env;\n"
   "@compute @workgroup_size(64)\n"
   "fn cs(@builtin(global_invocation_id) id : vec3u) {\n"
   "  let i = id.x;\n"
   "  if (i >= env.count) { return; }\n"
   "  let s = src[i];\n"
   "  for (var p = 0u; p < 6u; p++) {\n"
   "    if (dot(env.planes[p].xyz, s.pos.xyz) + env.planes[p].w\n"
   "        < -s.pos.w) { return; }\n"
   "  }\n"
   "  let k = atomicAdd(&args.instanceCount, 1u);\n"
   "  dst[k] = s;\n"
   "}\n"))

(define RENDER
  (string-append
   "struct Env { vp : mat4x4f, planes : array<vec4f, 6>,\n"
   "             count : u32, p0 : u32, p1 : u32, p2 : u32 }\n"
   "@group(0) @binding(0) var<uniform> env : Env;\n"
   "struct VOut { @builtin(position) pos : vec4f,\n"
   "              @location(0) c : vec4f }\n"
   "@vertex fn vs(@location(0) p : vec3f, @location(1) n : vec3f,\n"
   "              @location(2) inst : vec4f,\n"
   "              @location(3) color : vec4f) -> VOut {\n"
   "  var o : VOut;\n"
   "  let world = p * inst.w * 0.5 + inst.xyz;\n"
   "  o.pos = env.vp * vec4f(world, 1.0);\n"
   "  let d = max(dot(normalize(n), normalize(vec3f(0.4, 0.8, 0.3))),\n"
   "              0.0);\n"
   "  o.c = vec4f(color.rgb * (0.3 + 0.7 * d), 1.0);\n"
   "  return o;\n"
   "}\n"
   "@fragment fn fs(@location(0) c : vec4f) -> @location(0) vec4f {\n"
   "  return c;\n"
   "}\n"))

;; the field: a jittered grid of tinted boxes
(define seed 4321)
(define (rand01)
  (set! seed (remainder (+ (* seed 75) 74) 65537))
  (fl/ (fixnum->flonum seed) 65537.0))
(let init ((i 0))
  (when (< i N)
    (let* ((at (+ SBASE (* i 32)))
           (gx (fl- (fl* 300.0 (rand01)) 150.0))
           (gz (fl- (fl* 300.0 (rand01)) 150.0))
           (s (fl+ 0.4 (fl* 0.8 (rand01)))))
      (%mem-f32-set! at gx)
      (%mem-f32-set! (+ at 4) (fl* 0.5 s))
      (%mem-f32-set! (+ at 8) gz)
      (%mem-f32-set! (+ at 12) s)       ; radius rides w
      (%mem-f32-set! (+ at 16) (fl+ 0.3 (fl* 0.6 (rand01))))
      (%mem-f32-set! (+ at 20) (fl+ 0.3 (fl* 0.5 (rand01))))
      (%mem-f32-set! (+ at 24) (fl+ 0.4 (fl* 0.6 (rand01))))
      (%mem-f32-set! (+ at 28) 1.0))
    (init (+ i 1))))

(define box (mesh-box 2 2 2))
(define ICOUNT (mesh-index-count box))
(mesh-write! box GBASE (+ GBASE (mesh-vertex-bytes box)))

(define ready #f)
(define uploaded #f)
(gpu-attach! (get-element-by-id "c")
             (lambda ()
               (gpu-buffer! 0 (mesh-vertex-bytes box))
               (gpu-index! 1 (mesh-index-bytes box))
               (gpu-storage! 2 IBYTES)  ; the field, read-only
               (gpu-storage! 3 IBYTES)  ; the survivors
               (gpu-indirect! 4 20)
               (gpu-uniforms! 5 176)
               (gpu-compute! 6 CS)
               (gpu-compute-group*! 7 6 "2,3,4,5")
               (gpu-pipeline2! 8 RENDER
                               24 "float32x3,float32x3"
                               32 "float32x4,float32x4")
               (gpu-bindgroup! 9 8 5)
               (set! ready #t)))

(fx-ticks!
 (lambda (t dt)
   (when ready
     (let* ((a (fl* 0.15 t))
            (eye (v3 (fl* 60.0 (flcos a)) 26.0 (fl* 60.0 (flsin a))))
            (vp (m4-mul (m4-perspective 0.9 (fl/ 800.0 600.0) 0.5 160.0)
                        (m4-look-at eye (v3 0.0 0.0 0.0)
                                    (v3 0.0 1.0 0.0))))
            (planes (m4-frustum-planes vp)))
       (m4s-write! UBASE vp)
       (let plane ((i 0))
         (when (< i 6)
           (let ((p (vector-ref planes i))
                 (at (+ UBASE 64 (* i 16))))
             (%mem-f32-set! at (vector-ref p 0))
             (%mem-f32-set! (+ at 4) (vector-ref p 1))
             (%mem-f32-set! (+ at 8) (vector-ref p 2))
             (%mem-f32-set! (+ at 12) (vector-ref p 3)))
           (plane (+ i 1))))
       (%mem-i32-set! (+ UBASE 160) N)
       ;; the argument reset: indexCount, 0 instances, 0, 0, 0
       (%mem-i32-set! ABASE ICOUNT)
       (%mem-i32-set! (+ ABASE 4) 0)
       (%mem-i32-set! (+ ABASE 8) 0)
       (%mem-i32-set! (+ ABASE 12) 0)
       (%mem-i32-set! (+ ABASE 16) 0))
     (gpu-begin!)
     (unless uploaded
       (gpu-buffer-data! 0 GBASE (mesh-vertex-bytes box))
       (gpu-buffer-data! 1 (+ GBASE (mesh-vertex-bytes box))
                         (mesh-index-bytes box))
       (gpu-buffer-data! 2 SBASE IBYTES)
       (set! uploaded #t))
     (gpu-buffer-data! 5 UBASE 176)
     (gpu-buffer-data! 4 ABASE 20)
     (gpu-dispatch! 6 7 (quotient (+ N 63) 64))
     (gpu-clear! 0.03 0.04 0.08 1.0)
     (gpu-use-pipeline! 8)
     (gpu-set-group! 9)
     (gpu-bind-vbuf! 0)
     (gpu-bind-vbuf2! 3)
     (gpu-bind-ibuf! 1)
     (gpu-draw-indexed-indirect! 4 0)
     (gpu-flush!))))
