;; A rigged, animated, textured character: Fox.glb's 24 joints sample
;; through gltf-animate! every frame, the joint matrices upload as
;; one uniform array, and gltf-skin-vs blends four weighted bones per
;; vertex.  Keys 1 / 2 / 3 crossfade Survey / Walk / Run over 0.3s
;; (gltf-animate-blend! poses the old clip, then blends the new one
;; over it with the fade's weight).
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh) (web gltf))

(fx-init! (get-element-by-id "c"))
(fx-init-input!)

(define prog (fx-program! gltf-skin-vs mesh-tex-fs))
(define model #f)
(define anim 1)                          ; start walking
(define prev 1)                          ; what we fade away from
(define fade 1.0)                        ; 0 -> 1 over the crossfade

(define (want! a)
  (unless (= a anim)
    (set! prev anim)
    (set! anim a)
    (set! fade 0.0)))
(gltf-fetch! "assets/Fox.glb"
             (lambda (g)
               (gltf-load-textures! g
                                    (lambda (g2) (set! model g2)))))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 1.0 1000.0))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(fx-loop!
 (lambda (t dt)
   (cmd-clear! 0.06 0.08 0.13 1.0)
   (cmd-depth! #t)
   (cond ((key-down? "1") (want! 0))
         ((key-down? "2") (want! 1))
         ((key-down? "3") (want! 2)))
   (when model
     (if (fl<? fade 1.0)
         (begin
           (set! fade (fl+ fade (fl/ dt 0.3)))
           (gltf-animate-blend! model prev t anim t
                                (if (fl<? fade 1.0) fade 1.0)))
         (gltf-animate! model anim t))
     (let* ((a (fl* 0.3 t))
            (eye (v3 (fl* 170.0 (flsin a)) 90.0 (fl* 170.0 (flcos a))))
            (vp (m4-mul proj (m4-look-at eye (v3 0.0 45.0 0.0)
                                         (v3 0.0 1.0 0.0)))))
       (cmd-use-program! (fx-program-slot prog))
       (fx-uniform! prog 'u_light (v3-x light) (v3-y light) (v3-z light))
       (fx-uniform! prog 'u_ambient 0.4)
       (gltf-draw! model prog vp)))))
