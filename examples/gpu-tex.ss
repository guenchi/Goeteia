;; A textured, lit box on WebGPU, its shader authored ONCE as the
;; s-expression forms every dialect renders: (uniform sampler2D
;; u_tex) becomes a sampler + texture binding pair in WGSL, and
;; (texture2D u_tex v_uv) respells as textureSample.  The
;; checkerboard is procedural bytes written into staging memory and
;; shipped by one queue.writeTexture (gpu-texture-data!); the bind
;; group carries the uniform struct, the sampler and the view in
;; the order (web wgsl) declared them (gpu-texgroup!).
;; Needs a WebGPU browser.
(import (rnrs) (web js) (web dom) (web fx) (web mat) (web mesh)
        (web wgsl) (web gpu))

(define box (mesh-box 2.2 2.2 2.2))

(define vs-forms
  '((attribute vec3 a_pos)
    (attribute vec3 a_normal)
    (attribute vec2 a_uv)
    (uniform mat4 u_mvp)
    (uniform mat4 u_model)
    (varying vec3 v_n)
    (varying vec2 v_uv)
    (define (main) void
      (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
      (local vec4 nw (* u_model (vec4 a_normal (fl 0))))
      (set! v_n nw.xyz)
      (set! v_uv a_uv))))
(define fs-forms
  '((uniform sampler2D u_tex)
    (varying vec3 v_n)
    (varying vec2 v_uv)
    (define (main) void
      (local vec4 t (texture2D u_tex v_uv))
      (local vec3 l (normalize (vec3 (fl 0 50) (fl 0 80) (fl 0 40))))
      (local float d (max (dot (normalize v_n) l) (fl 0)))
      (set! gl_FragColor
            (vec4 (* t.rgb (+ (fl 0 30) (* (fl 0 70) d))) (fl 1))))))

(define WGSL (wgsl->string vs-forms fs-forms))
(define LAYOUT (wgsl-layout vs-forms))

;; ---- memory: uniforms, the checkerboard, then the mesh (uv) ----
(define UBASE 4096)
(define TEXBASE 8192)                   ; 64x64 rgba
(define VBASE (+ TEXBASE (* 64 64 4)))
(define IBASE (+ VBASE (mesh-vertex-bytes-uv box)))
(let ((need (- (+ IBASE (mesh-index-bytes box)) (* 65536 (%mem-size)))))
  (when (> need 0)
    (%mem-grow (quotient (+ need 65535) 65536))))
(mesh-write-uv! box VBASE IBASE)

;; the checkerboard, straight into staging bytes
(let px ((k 0))
  (when (< k (* 64 64))
    (let* ((cx (quotient (remainder k 64) 8))
           (cy (quotient (quotient k 64) 8))
           (dark? (= 1 (remainder (+ cx cy) 2)))
           (at (+ TEXBASE (* k 4))))
      (%mem-u8-set! at (if dark? 58 232))
      (%mem-u8-set! (+ at 1) (if dark? 90 228))
      (%mem-u8-set! (+ at 2) (if dark? 140 218))
      (%mem-u8-set! (+ at 3) 255))
    (px (+ k 1))))

(define (write-m4! at m)
  (let col ((k 0))
    (when (< k 16)
      (%mem-f32-set! (+ at (* k 4)) (vector-ref m k))
      (col (+ k 1)))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))

(define ready #f)
(define uploaded #f)
(gpu-attach! (get-element-by-id "c")
             (lambda ()
               (gpu-pipeline! 0 WGSL (car LAYOUT) (cdr LAYOUT))
               (gpu-buffer! 1 (mesh-vertex-bytes-uv box))
               (gpu-index! 2 (mesh-index-bytes box))
               (gpu-uniforms! 3 128)
               (gpu-texture! 4 64 64)
               (gpu-texture-data! 4 TEXBASE 64 64)
               (gpu-sampler! 5)
               (gpu-texgroup! 6 0 3 5 4) ; struct, sampler, view
               (set! ready #t)))

(fx-ticks!
 (lambda (t dt)
   (when ready
     (let* ((eye (v3 (fl* 5.0 (flsin (fl* 0.5 t))) 2.4
                     (fl* 5.0 (flcos (fl* 0.5 t)))))
            (vp (m4-mul proj (m4-look-at eye (v3 0.0 0.0 0.0)
                                         (v3 0.0 1.0 0.0))))
            (model (m4-mul (m4-rotate-x (fl* 0.3 t))
                           (m4-rotate-z (fl* 0.17 t)))))
       (write-m4! UBASE (m4-mul vp model))
       (write-m4! (+ UBASE 64) model))
     (gpu-begin!)
     (gpu-clear! 0.05 0.06 0.10 1.0)
     (gpu-use-pipeline! 0)
     (gpu-set-group! 6)
     (gpu-bind-vbuf! 1)
     (gpu-bind-ibuf! 2)
     (unless uploaded
       (gpu-buffer-data! 1 VBASE (mesh-vertex-bytes-uv box))
       (gpu-buffer-data! 2 IBASE (mesh-index-bytes box))
       (set! uploaded #t))
     (gpu-buffer-data! 3 UBASE 128)
     (gpu-draw-indexed! (mesh-index-count box))
     (gpu-flush!))))
