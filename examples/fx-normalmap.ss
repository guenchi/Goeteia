;; Normal mapping: the same torus twice.  The right one is plainly
;; lit; the left one samples a tangent-space normal map, and its
;; smooth surface reads as a grid of bumps that catch the light as it
;; turns.  The map itself is procedural -- a Scheme loop writes RGBA
;; bytes into staging memory and gl-texture-data! makes a texture of
;; them; the tangent frame comes from mesh-write-tan!.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh))

(fx-init! (get-element-by-id "c"))

;; ---- a procedural normal map: an 8x8 grid of smooth bumps ----
;; h = (1 - r^2/R^2)^2 inside each bump; the gradient is analytic,
;; so the normals are exact rather than finite-differenced
(define DIM 256)
(define nmap-base (fx-alloc! (* DIM DIM 4)))

(define (byte! at v)                    ; v in [-1,1] -> 0..255
  (%mem-u8-set! at (%fl->fx (fl* (fl+ (fl* v 0.5) 0.5) 255.0))))

(define (cell-coord p)                  ; pixel -> [-0.5,0.5) in cell
  (let ((c (fl* (fl/ (fixnum->flonum p) 256.0) 8.0)))
    (fl- (fl- c (flfloor c)) 0.5)))

(let gen ((p 0))
  (when (< p (* DIM DIM))
    (let* ((cu (cell-coord (remainder p DIM)))
           (cv (cell-coord (quotient p DIM)))
           (r2 (fl+ (fl* cu cu) (fl* cv cv)))
           (at (+ nmap-base (* p 4))))
      (if (fl<? r2 0.16)                ; inside the bump, radius 0.4
          (let* ((s (fl- 1.0 (fl/ r2 0.16)))
                 (gx (fl* -20.0 (fl* cu s)))   ; A * dh/dcu
                 (gy (fl* -20.0 (fl* cv s)))
                 (n (v3-normalize (v3 (fl- 0.0 gx) (fl- 0.0 gy) 1.0))))
            (byte! at (v3-x n))
            (byte! (+ at 1) (v3-y n))
            (byte! (+ at 2) (v3-z n)))
          (begin (byte! at 0.0) (byte! (+ at 1) 0.0) (byte! (+ at 2) 1.0)))
      (%mem-u8-set! (+ at 3) 255))
    (gen (+ p 1))))

(define nmap (fx-texture!))
(gl-texture-data! nmap nmap-base DIM DIM)

;; ---- the two programs and the two vertex streams ----
(define np (fx-program! mesh-normal-vs mesh-normal-fs))
(define lp (fx-program! mesh-lit-vs mesh-lit-fs))

(define torus (mesh-torus 1.35 0.6 48 24))
(define nbuf (fx-buffer!))
(define nibuf (fx-buffer!))
(define lbuf (fx-buffer!))
(define libuf (fx-buffer!))
(define nvbase (fx-alloc! (mesh-vertex-bytes-tan torus)))
(define nibase (fx-alloc! (mesh-index-bytes torus)))
(define lvbase (fx-alloc! (mesh-vertex-bytes torus)))
(define libase (fx-alloc! (mesh-index-bytes torus)))
(mesh-write-tan! torus nvbase nibase)
(mesh-write! torus lvbase libase)

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0.0 1.8 6.5) (v3 0.0 0.0 0.0)
                         (v3 0.0 1.0 0.0)))
(define vp (m4-mul proj view))
(define light (v3-normalize (v3 0.6 0.7 0.5)))
(define uploaded #f)

(define (common! prog model)
  (fx-uniform! prog 'u_mvp (m4-mul vp model))
  (fx-uniform! prog 'u_model model)
  (fx-uniform! prog 'u_light (v3-x light) (v3-y light) (v3-z light))
  (fx-uniform! prog 'u_ambient 0.25)
  (fx-uniform! prog 'u_color 0.62 0.60 0.58 1.0))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.08 0.09 0.13 1.0)
   (cmd-depth! #t)
   (let ((spin (m4-mul (m4-rotate-y (fl* 0.7 t))
                       (m4-rotate-x (fl* 0.4 t)))))
     ;; left: normal-mapped
     (fx-use! np nbuf)
     (cmd-bind-index! nibuf)
     (unless uploaded
       (cmd-buffer-data! nvbase (mesh-vertex-bytes-tan torus))
       (cmd-index-data! nibase (mesh-index-bytes torus)))
     (cmd-bind-texture! 0 nmap)
     (fx-uniform! np 'u_nmap 0)
     (common! np (m4-mul (m4-translate -2.2 0.0 0.0) spin))
     (cmd-draw-elements! GL-TRIANGLES (mesh-index-count torus))
     ;; right: the same mesh, plainly lit
     (fx-use! lp lbuf)
     (cmd-bind-index! libuf)
     (unless uploaded
       (cmd-buffer-data! lvbase (mesh-vertex-bytes torus))
       (cmd-index-data! libase (mesh-index-bytes torus))
       (set! uploaded #t))
     (common! lp (m4-mul (m4-translate 2.2 0.0 0.0) spin))
     (cmd-draw-elements! GL-TRIANGLES (mesh-index-count torus)))))
