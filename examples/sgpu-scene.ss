;; The declarative scene on WebGPU: the same sgl notation, culled
;; and drawn entirely GPU-side -- instances in storage buffers, a
;; compute cull compacting survivors, one indirect draw per shared
;; geometry.  A signal swings the torus assembly; the floor is a
;; textured plane (a checker painted here, no asset), sampled through
;; sgpu's textured pipeline.  Needs a WebGPU browser.
(import (rnrs) (web js) (web dom) (gfx fx) (gfx gpu) (gfx mat)
        (gfx sgpu) (web reactive))

(define angle (signal 0.0))

;; an 8x8 checker into staging, uploaded to a gpu texture (slot 40)
(define CHECK 200000)
(let ((need (- (+ CHECK 16384) (* 65536 (%mem-size)))))
  (when (> need 0)
    (%mem-grow (quotient (+ need 65535) 65536))))
(let row ((y 0))
  (when (< y 64)
    (let col ((x 0))
      (when (< x 64)
        (let* ((c (if (= 1 (remainder (+ (quotient x 8) (quotient y 8)) 2))
                      230 60))
               (at (+ CHECK (* (+ (* y 64) x) 4))))
          (%mem-u8-set! at c)
          (%mem-u8-set! (+ at 1) (quotient (* c 3) 4))
          (%mem-u8-set! (+ at 2) (quotient (* c 5) 6))
          (%mem-u8-set! (+ at 3) 255))
        (col (+ x 1))))
    (row (+ y 1))))

(define sc
  (sgl-gpu
   (camera (@ (fov 0.9) (position 0.0 6.0 16.0)
              (look-at 0.0 0.0 0.0) (near 0.1) (far 120.0)))
   (light (@ (direction 0.5 0.8 0.4) (ambient 0.3)))
   (group (@ (rotation-y ,(signal-ref angle)))
     (mesh (@ (geometry (torus 2.0 0.6 24 16))
              (position 0.0 1.5 0.0) (color 0.9 0.5 0.3)))
     (mesh (@ (geometry (box 1.2 1.2 1.2))
              (position 4.0 1.5 0.0) (color 0.4 0.7 0.9))))
   (mesh (@ (geometry (plane 40.0 40.0))
            (color 1.0 1.0 1.0) (texture 40)))
   ;; a pane of glass in front: alpha < 1 routes it to the blended
   ;; pass, drawn after the opaque scene with depth writes off
   (mesh (@ (geometry (box 6.0 4.0 0.2))
            (position 0.0 3.0 6.0) (color 0.5 0.75 0.95 0.35)))))

(gpu-attach!
 (get-element-by-id "c")
 (lambda ()
   (gpu-texture! 40 64 64)
   (gpu-texture-data! 40 CHECK 64 64)
   (sgpu-init! sc (get-element-by-id "c"))
   (fx-ticks!
    (lambda (t dt)
      (signal-set! angle (fl* 0.7 t))
      (gpu-begin!)
      (gpu-clear! 0.04 0.05 0.09 1.0)
      (sgpu-draw! sc)
      (gpu-flush!)))))
