;; A lit, indexed, depth-tested torus on WebGPU -- the 3D milestone
;; for (gfx gpu).  Geometry comes from (gfx mesh) (positions +
;; normals, u16 indices), the matrices from (gfx mat), and the
;; SHADER from the same s-expression forms (gfx glsl) renders:
;; (gfx wgsl) respells them as one WGSL module, and wgsl-layout
;; derives the pipeline's vertex formats from the same attribute
;; declarations.  The whole per-frame uniform state (mvp + model) is
;; one 128-byte struct written into a uniform buffer and bound as
;; @group(0) @binding(0): WebGPU has no uniform1f, so the struct IS
;; the uniform interface.  Needs a WebGPU browser.
(import (rnrs) (web js) (web dom) (gfx fx) (gfx mat) (gfx mesh)
        (gfx wgsl) (gfx gpu))

(define tor2 (mesh-torus 1.5 0.55 48 24))

(define vs-forms
  '((attribute vec3 a_pos)
    (attribute vec3 a_normal)
    (uniform mat4 u_mvp)
    (uniform mat4 u_model)
    (varying vec3 v_n)
    (define (main) void
      (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
      (local vec4 nw (* u_model (vec4 a_normal (fl 0))))
      (set! v_n nw.xyz))))
(define fs-forms
  '((varying vec3 v_n)
    (define (main) void
      (local vec3 l (normalize (vec3 (fl 0 50) (fl 0 80) (fl 0 40))))
      (local float d (max (dot (normalize v_n) l) (fl 0)))
      (local vec3 base (vec3 "0.95" "0.45" "0.35"))
      (set! gl_FragColor
            (vec4 (* base (+ (fl 0 25) (* (fl 0 75) d))) (fl 1))))))

(define WGSL (wgsl->string vs-forms fs-forms))
(define LAYOUT (wgsl-layout vs-forms))

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
(gpu-attach! (get-element-by-id "c")
             (lambda ()
               (gpu-pipeline! 0 WGSL (car LAYOUT) (cdr LAYOUT))
               (gpu-buffer! 1 (mesh-vertex-bytes tor2))
               (gpu-index! 2 (mesh-index-bytes tor2))
               (gpu-uniforms! 3 128)
               (gpu-bindgroup! 4 0 3)
               ;; the whole static draw freezes into a render bundle:
               ;; recorded once, the browser replays it with no
               ;; decode at all -- a frame is clear + one uniform
               ;; write + executeBundles
               (gpu-begin!)
               (gpu-use-pipeline! 0)
               (gpu-set-group! 4)
               (gpu-bind-vbuf! 1)
               (gpu-bind-ibuf! 2)
               (gpu-draw-indexed! (mesh-index-count tor2))
               (gpu-bundle! 5)
               ;; geometry ships once, outside any pass
               (gpu-begin!)
               (gpu-buffer-data! 1 VBASE (mesh-vertex-bytes tor2))
               (gpu-buffer-data! 2 IBASE (mesh-index-bytes tor2))
               (gpu-flush!)
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
     (gpu-buffer-data! 3 UBASE 128)      ; the uniform struct
     (gpu-execute! 5)                    ; the frozen draw
     (gpu-flush!))))
