;; Bloom, via (gfx post): the scene renders offscreen past white
;; (an HDR target), and the packaged chain does the rest -- a
;; luminance threshold at half resolution, a separable gaussian
;; ping-ponged twice, and a tonemapped composite.  What used to be
;; three hand-written shader passes is now three calls.
;; Needs WebGL 2.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx post) (gfx mat) (gfx mesh))

(fx-init! (get-element-by-id "c"))

(define scene-prog (fx-program! mesh-lit-vs mesh-lit-fs))
(define scene (fx-target-hdr! 800 600))  ; half-float: >1 survives
(define bloom (make-bloom 400 300))      ; threshold + blur + composite

;; a dim scene around one hot object
(define (upload m)
  (let* ((vbuf (fx-buffer!))
         (ibuf (fx-buffer!))
         (vbase (fx-alloc! (mesh-vertex-bytes m)))
         (ibase (fx-alloc! (mesh-index-bytes m))))
    (mesh-write! m vbase ibase)
    (vector vbuf ibuf vbase ibase (mesh-vertex-bytes m)
            (mesh-index-bytes m) (mesh-index-count m) #f)))

(define ground (upload (mesh-plane 14.0 14.0)))
(define torus (upload (mesh-torus 1.6 0.55)))
(define box (upload (mesh-box 1.4 1.4 1.4)))

(define (draw! obj model r g b vp)
  (fx-use! scene-prog (vector-ref obj 0))
  (cmd-bind-index! (vector-ref obj 1))
  (unless (vector-ref obj 7)
    (cmd-buffer-data! (vector-ref obj 2) (vector-ref obj 4))
    (cmd-index-data! (vector-ref obj 3) (vector-ref obj 5))
    (vector-set! obj 7 #t))
  (fx-uniform! scene-prog 'u_mvp (m4-mul vp model))
  (fx-uniform! scene-prog 'u_model model)
  (fx-uniform! scene-prog 'u_color r g b 1.0)
  (cmd-draw-elements! GL-TRIANGLES (vector-ref obj 6)))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.1 100.0))
(define view (m4-look-at (v3 0.0 3.0 8.0) (v3 0.0 0.5 0.0) (v3 0 1 0)))
(define vp (m4-mul proj view))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   ;; last frame left our targets bound for sampling
   (cmd-unbind-texture! 0)
   (cmd-unbind-texture! 1)
   ;; pass 1: the scene, offscreen
   (fx-bind-target! scene)
   (cmd-clear! 0.05 0.06 0.10 1.0)
   (cmd-depth! #t)
   (cmd-use-program! (fx-program-slot scene-prog))
   (fx-uniform! scene-prog 'u_light (v3-x light) (v3-y light) (v3-z light))
   (fx-uniform! scene-prog 'u_ambient 0.25)
   (draw! ground (m4-translate 0.0 -1.6 0.0) 0.22 0.25 0.32 vp)
   (draw! box (m4-mul (m4-translate -3.2 -0.9 -1.0)
                      (m4-rotate-y (fl* 0.4 t)))
          0.30 0.34 0.45 vp)
   ;; the hot one: an emissive color far past white -- the HDR
   ;; target keeps it, and only it crosses the threshold
   (draw! torus
          (m4-mul (m4-translate 0.0 0.6 0.0)
                  (m4-mul (m4-rotate-y t) (m4-rotate-x (fl* 0.6 t))))
          3.2 2.2 1.1 vp)
   (cmd-depth! #f)
   ;; the whole chain: threshold past white, blur, tonemapped add
   (bloom-run! bloom (fx-target-texture scene) 1.02 1.9)
   (bloom-composite! bloom (fx-target-texture scene) #f 'reinhard 1.1)))
