;; The lit scene again, declaratively: the sgl template builds the
;; meshes once, and the two signals drive the torus spin and the
;; sphere bob through reactive holes -- the frame itself is pure
;; arithmetic over current fields.  Compare fx-mesh.ss: same picture,
;; imperative draw calls.
(import (rnrs) (web js) (web dom) (web gl) (web fx) (web mat)
        (web reactive) (web scene))

(fx-init! (get-element-by-id "c"))

(define spin (signal 0.0))
(define bob (signal 0.4))

(define sc
  (sgl (camera (@ (fov 0.9) (position 0.0 3.5 9.0) (look-at 0.0 0.5 0.0)))
       (light (@ (direction 0.5 0.8 0.4) (ambient 0.25)))
       (mesh (@ (geometry (plane 14.0 14.0))
                (position 0.0 -1.6 0.0)
                (color 0.35 0.40 0.50)))
       (mesh (@ (geometry (torus 1.6 0.55))
                (position -1.8 0.6 0.0)
                (rotation-y ,(signal-ref spin))
                (rotation-x ,(fl* 0.6 (signal-ref spin)))
                (color 0.95 0.45 0.35)))
       (mesh (@ (geometry (sphere 1.0))
                (position-x 2.2)
                (position-y ,(signal-ref bob))
                (color 0.40 0.70 0.95)))))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (signal-set! spin t)
   (signal-set! bob (fl+ 0.4 (fl* 0.8 (flsin (fl* 1.5 t)))))
   (sgl-draw! sc)))
