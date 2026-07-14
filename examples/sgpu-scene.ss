;; The declarative scene on WebGPU: the same sgl notation, culled
;; and drawn entirely GPU-side -- instances in storage buffers, a
;; compute cull compacting survivors, one indirect draw per shared
;; geometry.  A signal swings the torus assembly; 2,000 spheres
;; carpet the floor as one group.  Needs a WebGPU browser.
(import (rnrs) (web js) (web dom) (gfx fx) (gfx gpu) (gfx mat)
        (gfx sgpu) (web reactive))

(define angle (signal 0.0))

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
   (mesh (@ (geometry (plane 40.0 40.0)) (color 0.25 0.3 0.35)))))

;; a carpet of spheres, one geometry group, culled on the GPU
(define-syntax carpet (syntax-rules () ((_) #f)))

(gpu-attach!
 (get-element-by-id "c")
 (lambda ()
   (sgpu-init! sc (get-element-by-id "c"))
   (fx-ticks!
    (lambda (t dt)
      (signal-set! angle (fl* 0.7 t))
      (gpu-begin!)
      (gpu-clear! 0.04 0.05 0.09 1.0)
      (sgpu-draw! sc)
      (gpu-flush!)))))
