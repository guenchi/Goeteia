;; Occlusion culling on the GPU: a hierarchical Z pyramid.  Three
;; walls render first (they are the picture's foreground AND the
;; occluders); the depth buffer then reduces into a max-mip pyramid
;; (gpu-hzb!), and the cull kernel tests every box's bounding
;; sphere against BOTH the frustum and the pyramid -- a sphere whose
;; nearest point is farther than everything already drawn over its
;; screen footprint cannot contribute a pixel, and never reaches the
;; vertex shader.  The indirect draw then renders exactly the
;; survivors.  Open with #nocull to skip the occlusion test: the
;; image is identical -- occlusion culling that changes the picture
;; is a bug.  Needs a WebGPU browser.
(import (rnrs) (web js) (web dom) (gfx fx) (gfx gpu) (gfx mat)
        (gfx mesh))

(define N 30000)
(define IBYTES (* N 32))
(define UBASE 4096)                     ; 256B uniforms
(define ABASE 4352)                     ; 20B indirect reset
(define GBASE 4416)                     ; box geometry
(define WBASE 8192)                     ; wall geometry
(define SBASE 65536)
(let ((need (- (+ SBASE IBYTES) (* 65536 (%mem-size)))))
  (when (> need 0)
    (%mem-grow (quotient (+ need 65535) 65536))))

(define CS
  (string-append
   "struct Inst { pos : vec4f, color : vec4f }\n"
   "struct Args { indexCount : u32, instanceCount : atomic<u32>,\n"
   "              firstIndex : u32, baseVertex : u32,\n"
   "              firstInstance : u32 }\n"
   "struct Env { vp : mat4x4f, view : mat4x4f,\n"
   "             planes : array<vec4f, 6>,\n"
   "             p00 : f32, p11 : f32, sw : f32, sh : f32,\n"
   "             pA : f32, count : u32, mode : u32, pd1 : u32 }\n"
   "@group(0) @binding(0) var<storage, read> src : array<Inst>;\n"
   "@group(0) @binding(1) var<storage, read_write> dst : array<Inst>;\n"
   "@group(0) @binding(2) var<storage, read_write> args : Args;\n"
   "@group(0) @binding(3) var<uniform> env : Env;\n"
   "@group(0) @binding(4) var hzb : texture_2d<f32>;\n"
   "@compute @workgroup_size(64)\n"
   "fn cs(@builtin(global_invocation_id) id : vec3u) {\n"
   "  let i = id.x;\n"
   "  if (i >= env.count) { return; }\n"
   "  let s = src[i];\n"
   "  for (var p = 0u; p < 6u; p++) {\n"
   "    if (dot(env.planes[p].xyz, s.pos.xyz) + env.planes[p].w\n"
   "        < -s.pos.w) { return; }\n"
   "  }\n"
   "  if (env.mode == 1u) {\n"
   "    let clip = env.vp * vec4f(s.pos.xyz, 1.0);\n"
   "    if (clip.w > s.pos.w) {\n"      ; safely in front: testable
   "      let ndc = clip.xy / clip.w;\n"
   "      let rx = s.pos.w * env.p00 / clip.w;\n"
   "      let ry = s.pos.w * env.p11 / clip.w;\n"
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
   "      let sphereNear = clamp((clip.z + env.pA * s.pos.w)\n"
   "                        / max(clip.w - s.pos.w, 0.001),\n"
   "                        0.0, 1.0);\n"
   "      if (sphereNear > d) { return; }\n"
   "    }\n"
   "  }\n"
   "  let k = atomicAdd(&args.instanceCount, 1u);\n"
   "  dst[k] = s;\n"
   "}\n"))

(define RENDER
  (string-append
   "struct Env { vp : mat4x4f, view : mat4x4f,\n"
   "             planes : array<vec4f, 6>,\n"
   "             p00 : f32, p11 : f32, sw : f32, sh : f32,\n"
   "             pA : f32, count : u32, mode : u32, pd1 : u32 }\n"
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

(define WALL
  (string-append
   "struct Env { vp : mat4x4f, view : mat4x4f,\n"
   "             planes : array<vec4f, 6>,\n"
   "             p00 : f32, p11 : f32, sw : f32, sh : f32,\n"
   "             pA : f32, count : u32, mode : u32, pd1 : u32 }\n"
   "@group(0) @binding(0) var<uniform> env : Env;\n"
   "struct VOut { @builtin(position) pos : vec4f,\n"
   "              @location(0) c : vec4f }\n"
   "@vertex fn vs(@location(0) p : vec3f, @location(1) n : vec3f)\n"
   "    -> VOut {\n"
   "  var o : VOut;\n"
   "  o.pos = env.vp * vec4f(p, 1.0);\n"
   "  let d = max(dot(normalize(n), normalize(vec3f(0.4, 0.8, 0.3))),\n"
   "              0.0);\n"
   "  o.c = vec4f(vec3f(0.25, 0.27, 0.33) * (0.4 + 0.6 * d), 1.0);\n"
   "  return o;\n"
   "}\n"
   "@fragment fn fs(@location(0) c : vec4f) -> @location(0) vec4f {\n"
   "  return c;\n"
   "}\n"))

;; the field: boxes on a plane behind three big walls
(define seed 4321)
(define (rand01)
  (set! seed (remainder (+ (* seed 75) 74) 65537))
  (fl/ (fixnum->flonum seed) 65537.0))
(let init ((i 0))
  (when (< i N)
    (let* ((at (+ SBASE (* i 32)))
           (gx (fl- (fl* 240.0 (rand01)) 120.0))
           (gz (fl- (fl* 200.0 (rand01)) 230.0))  ; mostly behind walls
           (sc (fl+ 0.5 (fl* 1.0 (rand01)))))
      (%mem-f32-set! at gx)
      (%mem-f32-set! (+ at 4) (fl* 0.5 sc))
      (%mem-f32-set! (+ at 8) gz)
      (%mem-f32-set! (+ at 12) sc)
      (%mem-f32-set! (+ at 16) (fl+ 0.4 (fl* 0.5 (rand01))))
      (%mem-f32-set! (+ at 20) (fl+ 0.4 (fl* 0.4 (rand01))))
      (%mem-f32-set! (+ at 24) (fl+ 0.5 (fl* 0.5 (rand01))))
      (%mem-f32-set! (+ at 28) 1.0))
    (init (+ i 1))))

(define box (mesh-box 2 2 2))
(define ICOUNT (mesh-index-count box))
(mesh-write! box GBASE (+ GBASE (mesh-vertex-bytes box)))

;; three walls: wide slabs between the camera and the field
(define walls (mesh-box 2 2 2))
(define WICOUNT (mesh-index-count walls))
;; write three scaled instances as plain geometry: bake them
(define WVB (* 3 (mesh-vertex-bytes walls)))
(let wall ((w 0))
  (when (< w 3)
    (let* ((vb (+ WBASE (* w (mesh-vertex-bytes walls))))
           (cx (vector-ref '#(-45.0 0.0 45.0) w))
           (sx 20.0) (sy 9.0) (sz 1.0))
      (mesh-write! walls vb (+ WBASE WVB (* w (mesh-index-bytes walls))))
      ;; rebase this wall's indices onto its verts in the shared vbuf
      (let ((ib (+ WBASE WVB (* w (mesh-index-bytes walls)))))
        (let ri ((k 0))
          (when (< k WICOUNT)
            (let* ((at (+ ib (* 2 k)))
                   (v (+ (%mem-u8-ref at)
                         (* 256 (%mem-u8-ref (+ at 1)))
                         (* 24 w))))
              (%mem-u8-set! at (remainder v 256))
              (%mem-u8-set! (+ at 1) (quotient v 256)))
            (ri (+ k 1)))))
      ;; scale/translate the freshly written vertices in place
      (let v ((k 0))
        (when (< k (mesh-vert-count walls))
          (let ((at (+ vb (* k 24))))
            (%mem-f32-set! at (fl+ (fl* (%mem-f32-ref at) sx) cx))
            (%mem-f32-set! (+ at 4)
                           (fl+ (fl* (%mem-f32-ref (+ at 4)) sy) 4.0))
            (%mem-f32-set! (+ at 8)
                           (fl* (%mem-f32-ref (+ at 8)) sz)))
          (v (+ k 1)))))
    (wall (+ w 1))))

(define nocull
  (let ((h (js->string (js-eval "location.hash"))))
    (and (> (string-length h) 1) (string=? h "#nocull"))))

(define ready #f)
(define uploaded #f)
(gpu-attach! (get-element-by-id "c")
             (lambda ()
               (gpu-buffer! 0 (mesh-vertex-bytes box))
               (gpu-index! 1 (mesh-index-bytes box))
               (gpu-storage! 2 IBYTES)
               (gpu-storage! 3 IBYTES)
               (gpu-indirect! 4 20)
               (gpu-uniforms! 5 256)
               (gpu-hzb-init! 10 800 600)
               (gpu-compute! 6 CS)
               (gpu-compute-groupx! 7 6 "2,3,4,5,t10")
               (gpu-pipeline2! 8 RENDER
                               24 "float32x3,float32x3"
                               32 "float32x4,float32x4")
               (gpu-bindgroup! 9 8 5)
               (gpu-buffer! 11 WVB)
               (gpu-index! 12 (* 3 (mesh-index-bytes walls)))
               (gpu-pipeline! 13 WALL 24 "float32x3,float32x3")
               (gpu-bindgroup! 14 13 5)
               (set! ready #t)))

;; WebGPU clips z to [0, w]: this projection lands depth in [0,1]
(define (persp01 fovy aspect near far)
  (let* ((f (fl/ 1.0 (fltan (fl/ fovy 2.0))))
         (nf (fl/ 1.0 (fl- near far))))
    (vector (fl/ f aspect) 0.0 0.0 0.0
            0.0 f 0.0 0.0
            0.0 0.0 (fl* far nf) -1.0
            0.0 0.0 (fl* (fl* far near) nf) 0.0)))
(define eye (v3 0.0 10.0 40.0))
(define view (m4-look-at eye (v3 0.0 2.0 -40.0) (v3 0.0 1.0 0.0)))
(define proj (persp01 0.9 (fl/ 800.0 600.0) 0.5 400.0))
(define vp (m4-mul proj view))
(define planes (m4-frustum-planes vp))

(fx-ticks!
 (lambda (t dt)
   (when ready
     (m4s-write! UBASE vp)
     (m4s-write! (+ UBASE 64) view)
     (let plane ((i 0))
       (when (< i 6)
         (let ((p (vector-ref planes i))
               (at (+ UBASE 128 (* i 16))))
           (%mem-f32-set! at (vector-ref p 0))
           (%mem-f32-set! (+ at 4) (vector-ref p 1))
           (%mem-f32-set! (+ at 8) (vector-ref p 2))
           (%mem-f32-set! (+ at 12) (vector-ref p 3)))
         (plane (+ i 1))))
     (%mem-f32-set! (+ UBASE 224) (vector-ref proj 0))   ; p00
     (%mem-f32-set! (+ UBASE 228) (vector-ref proj 5))   ; p11
     (%mem-f32-set! (+ UBASE 232) 800.0)
     (%mem-f32-set! (+ UBASE 236) 600.0)
     (%mem-f32-set! (+ UBASE 240) (vector-ref proj 10))  ; pA
     (%mem-i32-set! (+ UBASE 244) N)
     (%mem-i32-set! (+ UBASE 248) (if nocull 0 1))
     (%mem-i32-set! ABASE ICOUNT)
     (%mem-i32-set! (+ ABASE 4) 0)
     (%mem-i32-set! (+ ABASE 8) 0)
     (%mem-i32-set! (+ ABASE 12) 0)
     (%mem-i32-set! (+ ABASE 16) 0)
     (gpu-begin!)
     (unless uploaded
       (gpu-buffer-data! 0 GBASE (mesh-vertex-bytes box))
       (gpu-buffer-data! 1 (+ GBASE (mesh-vertex-bytes box))
                         (mesh-index-bytes box))
       (gpu-buffer-data! 2 SBASE IBYTES)
       (gpu-buffer-data! 11 WBASE WVB)
       (gpu-buffer-data! 12 (+ WBASE WVB)
                         (* 3 (mesh-index-bytes walls)))
       (set! uploaded #t))
     (gpu-buffer-data! 5 UBASE 256)
     (gpu-buffer-data! 4 ABASE 20)
     ;; pass 1: the walls -- the occluders are part of the picture
     (gpu-clear! 0.03 0.04 0.08 1.0)
     (gpu-use-pipeline! 13)
     (gpu-set-group! 14)
     (gpu-bind-vbuf! 11)
     (gpu-bind-ibuf! 12)
     (gpu-draw-indexed! (* 3 WICOUNT))
     (gpu-end-pass!)
     ;; the pyramid, then the cull against it
     (gpu-hzb!)
     (gpu-dispatch! 6 7 (quotient (+ N 63) 64))
     ;; pass 2: the survivors, over the walls' image and depth
     (gpu-use-pipeline! 8)
     (gpu-set-group! 9)
     (gpu-bind-vbuf! 0)
     (gpu-bind-vbuf2! 3)
     (gpu-bind-ibuf! 1)
     (gpu-draw-indexed-indirect! 4 0)
     (gpu-flush!))))
