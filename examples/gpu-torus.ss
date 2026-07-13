;; A lit, indexed, depth-tested torus on WebGPU -- the 3D milestone
;; for (web gpu).  Geometry comes from (web mesh) (positions +
;; normals, u16 indices), the matrices from (web mat), and the whole
;; per-frame uniform state (mvp + model) is one 128-byte struct
;; written into a uniform buffer and bound as @group(0) @binding(0):
;; WebGPU has no uniform1f, so the struct IS the uniform interface.
;; Needs a WebGPU browser.
(import (rnrs) (web js) (web dom) (web fx) (web mat) (web mesh)
        (web gpu))

(define tor2 (mesh-torus 1.5 0.55 48 24))

(define WGSL
  (string-append
   "struct U { mvp : mat4x4f, model : mat4x4f };\n"
   "@group(0) @binding(0) var<uniform> u : U;\n"
   "struct VOut { @builtin(position) pos : vec4f,\n"
   "              @location(0) n : vec3f };\n"
   "@vertex fn vs(@location(0) p : vec3f, @location(1) n : vec3f)\n"
   "    -> VOut {\n"
   "  var o : VOut;\n"
   "  o.pos = u.mvp * vec4f(p, 1.0);\n"
   "  o.n = (u.model * vec4f(n, 0.0)).xyz;\n"
   "  return o;\n"
   "}\n"
   "@fragment fn fs(@location(0) n : vec3f) -> @location(0) vec4f {\n"
   "  let l = normalize(vec3f(0.5, 0.8, 0.4));\n"
   "  let d = max(dot(normalize(n), l), 0.0);\n"
   "  let base = vec3f(0.95, 0.45, 0.35);\n"
   "  return vec4f(base * (0.25 + 0.75 * d), 1.0);\n"
   "}\n"))

;; ---- memory: commands below 4096, then uniforms, then the mesh ----
(define UBASE 4096)
(define VBASE 8192)
(define IBASE (+ VBASE (mesh-vertex-bytes tor2)))
(let ((need (- (+ IBASE (mesh-index-bytes tor2))
               (* 65536 (%mem-size)))))
  (when (> need 0)
    (%mem-grow (quotient (+ need 65535) 65536))))
(mesh-write! tor2 VBASE IBASE)

(define (write-m4! at m)                ; column-major, as WGSL reads
  (let col ((k 0))
    (when (< k 16)
      (%mem-f32-set! (+ at (* k 4)) (vector-ref m k))
      (col (+ k 1)))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))

(define ready #f)
(define uploaded #f)
(gpu-attach! (get-element-by-id "c")
             (lambda ()
               (gpu-pipeline! 0 WGSL 24 "float32x3,float32x3")
               (gpu-buffer! 1 (mesh-vertex-bytes tor2))
               (gpu-index! 2 (mesh-index-bytes tor2))
               (gpu-uniforms! 3 128)
               (gpu-bindgroup! 4 0 3)
               (set! ready #t)))

(fx-ticks!
 (lambda (t dt)
   (when ready
     (let* ((eye (v3 (fl* 5.0 (flsin (fl* 0.6 t))) 2.2
                     (fl* 5.0 (flcos (fl* 0.6 t)))))
            (vp (m4-mul proj (m4-look-at eye (v3 0.0 0.0 0.0)
                                         (v3 0.0 1.0 0.0))))
            (model (m4-mul (m4-rotate-x (fl* 0.4 t))
                           (m4-rotate-z (fl* 0.23 t)))))
       (write-m4! UBASE (m4-mul vp model))
       (write-m4! (+ UBASE 64) model))
     (gpu-begin!)
     (gpu-clear! 0.05 0.06 0.10 1.0)
     (gpu-use-pipeline! 0)
     (gpu-set-group! 4)
     (gpu-bind-vbuf! 1)
     (gpu-bind-ibuf! 2)
     (unless uploaded
       (gpu-buffer-data! 1 VBASE (mesh-vertex-bytes tor2))
       (gpu-buffer-data! 2 IBASE (mesh-index-bytes tor2))
       (set! uploaded #t))
     (gpu-buffer-data! 3 UBASE 128)
     (gpu-draw-indexed! (mesh-index-count tor2))
     (gpu-flush!))))
