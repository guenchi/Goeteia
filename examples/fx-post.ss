;; Post-processing: the lit scene renders into an offscreen target
;; (fx-target!), then one fullscreen pass samples it back with a wavy
;; distortion and a vignette.  Two passes, two draw-call groups, one
;; command buffer -- render-to-texture is the door to shadows, bloom
;; and every screen-space effect.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

(define scene-prog (fx-program! mesh-lit-vs mesh-lit-fs))
(define scene (fx-target-msaa! 800 600 4)) ; offscreen, antialiased

;; the screen pass: sample the scene with a ripple and darken edges
(define post
  (fx-fullscreen!
   '((precision mediump float)
     (uniform sampler2D u_scene)
     (uniform float u_time)
     (uniform vec2 u_resolution)
     (define (main) void
       (local vec2 uv (/ gl_FragCoord.xy u_resolution))
       (local vec2 warped
              (vec2 (+ uv.x (* (fl 0 4) (/ (sin (+ (* uv.y (fl 40))
                                                   (* u_time (fl 3))))
                                           (fl 100))))
                    uv.y))
       (local vec4 c (texture2D u_scene warped))
       (local vec2 d (- uv (vec2 (fl 0 50) (fl 0 50))))
       (local float vig (- (fl 1 15) (* (fl 1 20) (dot d d))))
       (set! gl_FragColor (vec4 (* c.rgb vig) (fl 1)))))))

;; a small scene to distort
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
   (cmd-unbind-texture! 0)                ; the scene was sampled last frame
   ;; pass 1: the scene, into the offscreen target
   (fx-bind-target! scene)
   (cmd-clear! 0.06 0.07 0.12 1.0)
   (cmd-depth! #t)
   (cmd-use-program! (fx-program-slot scene-prog))
   (fx-uniform! scene-prog 'u_light (v3-x light) (v3-y light) (v3-z light))
   (fx-uniform! scene-prog 'u_ambient 0.25)
   (draw! ground (m4-translate 0.0 -1.6 0.0) 0.35 0.40 0.50 vp)
   (draw! torus
          (m4-mul (m4-translate 0.0 0.6 0.0)
                  (m4-mul (m4-rotate-y t) (m4-rotate-x (fl* 0.6 t))))
          0.95 0.45 0.35 vp)
   ;; pass 2: back to the canvas, through the post shader
   (fx-resolve! scene)                   ; blit the samples down
   (fx-bind-canvas!)
   (cmd-depth! #f)
   (fx-fullscreen-use! post t)
   (cmd-bind-texture! 0 (fx-target-texture scene))
   (fx-uniform! (fx-quad-program post) 'u_scene 0)
   (fx-fullscreen-draw! post)))
