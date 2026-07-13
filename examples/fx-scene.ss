;; The lit scene again, declaratively -- now with materials.  The
;; sgl template builds the meshes once; two signals drive the torus
;; spin and the sphere bob through reactive holes.  The ground is a
;; checkerboard painted here ((texture ...) switches that mesh to
;; the uv program), the sphere is metal ((metallic)/(roughness)
;; switch it to PBR against the scene's probe, baked by (gfx ibl)
;; from a tiny procedural sky), and the far torus only costs its
;; matrix while the camera cannot see it: sgl-draw! culls against
;; the frustum.  Compare fx-mesh.ss: same picture, imperative.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx fx) (gfx mat)
        (gfx ibl) (web reactive) (gfx scene))

(fx-init! (get-element-by-id "c"))

;; ---- an 8x8 checkerboard on a 64px canvas, uploaded once ----
(define tex (fx-texture!))
(let* ((cv (js-method (js-get (js-global) "document")
                      "createElement" "canvas"))
       (ctx (begin (js-set! cv "width" 64)
                   (js-set! cv "height" 64)
                   (js-method cv "getContext" "2d"))))
  (js-set! ctx "fillStyle" "#e8e4da")
  (js-method ctx "fillRect" 0 0 64 64)
  (js-set! ctx "fillStyle" "#3a5a8c")
  (let cell ((k 0))
    (when (< k 64)
      (let ((cx (remainder k 8)) (cy (quotient k 8)))
        (when (= 1 (remainder (+ cx cy) 2))
          (js-method ctx "fillRect" (* cx 8) (* cy 8) 8 8)))
      (cell (+ k 1))))
  (gl-texture-upload! tex cv))

;; ---- a small dusk gradient sky, prefiltered into a probe ----
(define DIM 16)
(define sky-base (fx-alloc! (* 6 DIM DIM 4)))
(let px ((k 0))
  (when (< k (* 6 DIM DIM))
    (let* ((face (quotient k (* DIM DIM)))
           (row (quotient (remainder k (* DIM DIM)) DIM))
           (up (fl- 1.0 (fl/ (fixnum->flonum row) 15.0)))
           (sky? (< face 4))            ; crude: side faces shade by row
           (at (+ sky-base (* k 4))))
      (if (= face 3)                    ; -y: the ground's brown
          (begin (%mem-u8-set! at 70) (%mem-u8-set! (+ at 1) 60)
                 (%mem-u8-set! (+ at 2) 52))
          (begin
            (%mem-u8-set! at (%fl->fx (fl+ 120.0 (fl* 80.0 up))))
            (%mem-u8-set! (+ at 1) (%fl->fx (fl+ 110.0 (fl* 50.0 up))))
            (%mem-u8-set! (+ at 2) (%fl->fx (fl+ 130.0 (fl* 30.0 up))))))
      (%mem-u8-set! (+ at 3) 255))
    (px (+ k 1))))
(define sky-map (fx-slot!))
(gl-cubemap! sky-map sky-base DIM)
(define lut (ibl-brdf-lut!))
(define env (ibl-prefilter! sky-map DIM 4))

(define spin (signal 0.0))
(define bob (signal 0.4))

(define sc
  (sgl (camera (@ (fov 0.9) (position 0.0 3.5 9.0) (look-at 0.0 0.5 0.0)
                  (near 0.1) (far 40.0)))
       (light (@ (direction 0.5 0.8 0.4) (ambient 0.25)))
       (probe (@ (sky ,env) (lut ,lut) (mips 3)))
       (mesh (@ (geometry (plane 14.0 14.0))
                (position 0.0 -1.6 0.0)
                (texture ,tex)))
       (mesh (@ (geometry (torus 1.6 0.55))
                (position -1.8 0.6 0.0)
                (rotation-y ,(signal-ref spin))
                (rotation-x ,(fl* 0.6 (signal-ref spin)))
                (color 0.95 0.45 0.35)))
       (mesh (@ (geometry (sphere 1.0))
                (position-x 2.2)
                (position-y ,(signal-ref bob))
                (color 0.85 0.88 0.92)
                (metallic 1.0) (roughness 0.15)))
       ;; parked past the far plane: culled until you move it
       (mesh (@ (geometry (torus 1.6 0.55))
                (position 0.0 0.6 -80.0)
                (color 0.4 0.9 0.4)))))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-unbind-texture! 0)
   (cmd-unbind-texture! 1)
   (signal-set! spin t)
   (signal-set! bob (fl+ 0.4 (fl* 0.8 (flsin (fl* 1.5 t)))))
   (sgl-draw! sc)))
