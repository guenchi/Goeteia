;; A rigged, animated, textured character: Fox.glb's 24 joints sample
;; through the animation state machine every frame, the joint
;; matrices upload as one uniform array, and gltf-skin-vs blends four
;; weighted bones per vertex.  Keys 1 / 2 / 3 are anim-goto! into
;; Survey / Walk / Run; the machine crossfades over 0.3s while both
;; clips' clocks keep running.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx gltf))

(fx-init! (get-element-by-id "c"))
(fx-init-input!)

(define prog (fx-program! gltf-skin-vs mesh-tex-fs))
(define model #f)
(define machine #f)

(gltf-fetch! "assets/Fox.glb"
             (lambda (g)
               (gltf-load-textures! g
                                    (lambda (g2)
                                      (set! model g2)
                                      (set! machine
                                            (anim-machine g2
                                                          '((walk . 1)
                                                            (survey . 0)
                                                            (run . 2))
                                                          0.3))))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 1.0 1000.0))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.06 0.08 0.13 1.0)
   (cmd-depth! #t)
   (when machine
     (cond ((key-down? "1") (anim-goto! machine 'survey))
           ((key-down? "2") (anim-goto! machine 'walk))
           ((key-down? "3") (anim-goto! machine 'run))))
   (when model
     (anim-update! machine dt)
     (let* ((a (fl* 0.3 t))
            (eye (v3 (fl* 170.0 (flsin a)) 90.0 (fl* 170.0 (flcos a))))
            (vp (m4-mul proj (m4-look-at eye (v3 0.0 45.0 0.0)
                                         (v3 0.0 1.0 0.0)))))
       (cmd-use-program! (fx-program-slot prog))
       (fx-uniform! prog 'u_light (v3-x light) (v3-y light) (v3-z light))
       (fx-uniform! prog 'u_ambient 0.4)
       (gltf-draw! model prog vp)))))
