;; The PBR calibration scene: a 5x5 grid of spheres, metallic rising
;; front to back, roughness left to right, lit by one sun and a REAL
;; light probe -- (web ibl) prefilters the procedural sky's mip chain
;; with GGX at rising roughness and bakes the split-sum BRDF lookup
;; table, so the ambient term is Karis' split-sum, not a mip-bias
;; approximation.  Needs WebGL 2.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web ibl) (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

;; ---- the sky, baked (as in fx-skybox) ----
(define DIM 64)
(define sun (v3-normalize (v3 0.55 0.45 0.35)))
(define sky-base (fx-alloc! (* 6 DIM DIM 4)))

(define (clamp01 v) (if (fl<? v 0.0) 0.0 (if (fl<? 1.0 v) 1.0 v)))
(define (byte! at v) (%mem-u8-set! at (%fl->fx (fl* (clamp01 v) 255.0))))
(define (mix a b k) (fl+ a (fl* (fl- b a) k)))

(define (face-dir i a b)
  (case i
    ((0) (v3 1.0 (fl- 0.0 b) (fl- 0.0 a)))
    ((1) (v3 -1.0 (fl- 0.0 b) a))
    ((2) (v3 a 1.0 b))
    ((3) (v3 a -1.0 (fl- 0.0 b)))
    ((4) (v3 a (fl- 0.0 b) 1.0))
    (else (v3 (fl- 0.0 a) (fl- 0.0 b) -1.0))))

(let face ((i 0))
  (when (< i 6)
    (let pixel ((p 0))
      (when (< p (* DIM DIM))
        (let* ((s (fl/ (fl+ (fixnum->flonum (remainder p DIM)) 0.5) 64.0))
               (t (fl/ (fl+ (fixnum->flonum (quotient p DIM)) 0.5) 64.0))
               (d (v3-normalize
                   (face-dir i (fl- (fl* 2.0 s) 1.0)
                             (fl- (fl* 2.0 t) 1.0))))
               (y (v3-y d))
               (glow (clamp01 (fl/ (fl- (v3-dot d sun) 0.95) 0.05)))
               (k (fl* glow glow))
               (at (+ sky-base (* (+ (* i (* DIM DIM)) p) 4))))
          (if (fl<? y 0.0)
              (begin
                (byte! at (mix 0.42 0.20 (fl- 0.0 y)))
                (byte! (+ at 1) (mix 0.38 0.17 (fl- 0.0 y)))
                (byte! (+ at 2) (mix 0.33 0.14 (fl- 0.0 y))))
              (begin
                (byte! at (fl+ (mix 0.72 0.16 y) k))
                (byte! (+ at 1) (fl+ (mix 0.80 0.32 y) (fl* k 0.9)))
                (byte! (+ at 2) (fl+ (mix 0.90 0.60 y) (fl* k 0.6)))))
          (%mem-u8-set! (+ at 3) 255))
        (pixel (+ p 1))))
    (face (+ i 1))))

(define sky-map (fx-slot!))
(gl-cubemap! sky-map sky-base DIM)

;; the real probe: GGX-prefiltered mips + the split-sum BRDF table
(define lut (ibl-brdf-lut!))
(define env (ibl-prefilter! sky-map DIM 6))

(define sky-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_vp)
     (varying vec3 v_dir)
     (define (main) void
       (set! v_dir a_pos)
       (local vec4 p (* u_vp (vec4 a_pos (fl 0))))
       (set! gl_Position p.xyww)))
   '((precision mediump float)
     (uniform samplerCube u_sky)
     (varying vec3 v_dir)
     (define (main) void
       (set! gl_FragColor (textureCube u_sky v_dir))))))

(define pbr-p (fx-program! mesh-pbr-vs mesh-pbr-fs))

;; ---- geometry ----
(define (upload m)
  (let* ((vbuf (fx-buffer!)) (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write! m vbase ibase)
    (vector vbuf ibuf vbase ibase (mesh-vertex-bytes m)
            (mesh-index-bytes m) (mesh-index-count m) #f)))
(define (bind-upload! prog obj)
  (fx-use! prog (vector-ref obj 0))
  (cmd-bind-index! (vector-ref obj 1))
  (unless (vector-ref obj 7)
    (cmd-buffer-data! (vector-ref obj 2) (vector-ref obj 4))
    (cmd-index-data! (vector-ref obj 3) (vector-ref obj 5))
    (vector-set! obj 7 #t)))

(define cube (upload (mesh-box 2.0 2.0 2.0)))
(define ball (upload (mesh-sphere 0.78 40 20)))

(define proj (m4-perspective 0.8 (/ 800.0 600.0) 0.1 100.0))

(define (grid-v i) (fl* 2.0 (fl- (fixnum->flonum i) 2.0)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.0 0.0 0.0 1.0)
   (let* ((a (fl* 0.12 t))
          (eye (v3 (fl* 13.0 (flsin a)) 5.5 (fl* 13.0 (flcos a))))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 0.0 0.0)
                                       (v3 0.0 1.0 0.0)))))
     ;; the sky, depth off
     (cmd-depth! #f)
     (bind-upload! sky-p cube)
     (cmd-bind-cubemap! 0 sky-map)
     (fx-uniform! sky-p 'u_sky 0)
     (fx-uniform! sky-p 'u_vp vp)
     (cmd-draw-elements! GL-TRIANGLES (vector-ref cube 6))
     ;; the grid: metallic front to back, roughness left to right
     (cmd-depth! #t)
     (bind-upload! pbr-p ball)
     (cmd-bind-cubemap! 0 env)
     (cmd-bind-texture! 1 lut)
     (fx-uniform! pbr-p 'u_sky 0)
     (fx-uniform! pbr-p 'u_lut 1)
     (fx-uniform! pbr-p 'u_mips 5.0)
     (fx-uniform! pbr-p 'u_light (v3-x sun) (v3-y sun) (v3-z sun))
     (fx-uniform! pbr-p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye))
     (fx-uniform! pbr-p 'u_albedo 0.75 0.22 0.15 1.0)
     (let row ((i 0))
       (when (< i 5)
         (fx-uniform! pbr-p 'u_metallic (fl/ (fixnum->flonum i) 4.0))
         (let col ((j 0))
           (when (< j 5)
             (let ((m (m4-translate (grid-v j) 0.0 (grid-v i))))
               (fx-uniform! pbr-p 'u_roughness
                            (fl+ 0.05 (fl* 0.2375 (fixnum->flonum j))))
               (fx-uniform! pbr-p 'u_mvp (m4-mul vp m))
               (fx-uniform! pbr-p 'u_model m)
               (cmd-draw-elements! GL-TRIANGLES (vector-ref ball 6)))
             (col (+ j 1))))
         (row (+ i 1)))))))
