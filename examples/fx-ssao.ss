;; Screen-space ambient occlusion, the depth-buffer way: the scene
;; renders twice (lit, and linear view depth into a half-float
;; target), a fullscreen pass compares each pixel's depth with a
;; ring of neighbors -- nearer neighbors occlude, with a range
;; falloff so distant geometry does not -- a box blur softens the
;; result, and the composite multiplies it under the lit scene.
;; Corners, creases and contact points darken.  Needs WebGL 2.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh))

(fx-init! (get-element-by-id "c"))

(define FAR 60.0)

(define lit-p (fx-program! mesh-lit-vs mesh-lit-fs))

;; linear view depth, normalized by FAR, into the red channel
(define depth-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform vec3 u_eye)
     (uniform float u_far)
     (varying float v_d)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_d (/ (distance a_pos u_eye) u_far))))
   '((precision mediump float)
     (varying float v_d)
     (define (main) void
       (set! gl_FragColor (vec4 v_d (fl 0) (fl 0) (fl 1)))))))

;; eight taps on two rings; occlusion falls off with depth gap
(define ssao-q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform sampler2D u_g)
     (uniform vec2 u_texel)
     (define (occ (vec2 uv) (vec2 off) (float d)) float
       (local vec4 s (texture2D u_g (+ uv off)))
       (local float dz (- d s.r))        ; > 0: the neighbor is nearer
       (return (* (step "0.003" dz)
                  (max (- (fl 1) (* dz "14.0")) (fl 0)))))
     (define (main) void
       (local vec2 uv (* gl_FragCoord.xy u_texel))
       (local vec4 g (texture2D u_g uv))
       (local float d g.r)
       (local float r (/ "5.0" (max (* d "60.0") "2.0")))
       (local vec2 px (* u_texel r))
       (local float a (occ uv (* px (vec2 (fl 8) (fl 0))) d))
       (set! a (+ a (occ uv (* px (vec2 (- (fl 8)) (fl 0))) d)))
       (set! a (+ a (occ uv (* px (vec2 (fl 0) (fl 8))) d)))
       (set! a (+ a (occ uv (* px (vec2 (fl 0) (- (fl 8)))) d)))
       (set! a (+ a (occ uv (* px (vec2 (fl 4) (fl 4))) d)))
       (set! a (+ a (occ uv (* px (vec2 (- (fl 4)) (fl 4))) d)))
       (set! a (+ a (occ uv (* px (vec2 (fl 4) (- (fl 4)))) d)))
       (set! a (+ a (occ uv (* px (vec2 (- (fl 4)) (- (fl 4)))) d)))
       (local float ao (- (fl 1) (* "0.09" a)))
       (set! gl_FragColor (vec4 ao ao ao (fl 1)))))))

;; a 4-tap box blur knocks the ring pattern down
(define blur-q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform sampler2D u_src)
     (uniform vec2 u_texel)
     (define (main) void
       (local vec2 uv (* gl_FragCoord.xy u_texel))
       (local vec4 a (texture2D u_src (+ uv (* u_texel (vec2 (fl 1) (fl 1))))))
       (local vec4 b (texture2D u_src (+ uv (* u_texel (vec2 (- (fl 1)) (fl 1))))))
       (local vec4 c (texture2D u_src (+ uv (* u_texel (vec2 (fl 1) (- (fl 1)))))))
       (local vec4 d (texture2D u_src (+ uv (* u_texel (vec2 (- (fl 1)) (- (fl 1)))))))
       (set! gl_FragColor (* (+ (+ a b) (+ c d)) (fl 0 25)))))))

(define comp-q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform sampler2D u_scene)
     (uniform sampler2D u_ao)
     (uniform vec2 u_texel)
     (define (main) void
       (local vec2 uv (* gl_FragCoord.xy u_texel))
       (local vec4 c (texture2D u_scene uv))
       (local vec4 av (texture2D u_ao uv))
       (local float ao (* av.r av.r))
       (set! gl_FragColor (vec4 (* c.rgb ao) (fl 1)))))))

;; ---- a corner-heavy scene ----
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

(define ground (upload (mesh-plane 40.0 40.0)))
(define box (upload (mesh-box 3.0 3.0 3.0)))
(define ball (upload (mesh-sphere 1.6 32 16)))
(define torus (upload (mesh-torus 2.2 0.7 32 16)))

;; boxes stacked into a corner, a sphere resting against them
(define models
  (list (cons box (m4-translate -2.0 1.5 -1.0))
        (cons box (m4-translate 1.2 1.5 -2.2))
        (cons box (m4-translate -0.5 4.5 -1.6))
        (cons ball (m4-translate 2.4 1.6 1.8))
        (cons torus (m4-mul (m4-translate -3.5 0.72 3.2)
                            (m4-rotate-x 1.5707963)))))

(define scene-t (fx-target! 800 600))
(define depth-t (fx-target-hdr! 800 600))
(define ao-t (fx-target! 400 300))
(define blur-t (fx-target! 400 300))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.5 60.0))
(define light (v3-normalize (v3 0.5 0.8 0.4)))

(define (draw-scene! prog each)
  (bind-upload! prog ground)
  (each ground (m4-identity))
  (cmd-draw-elements! GL-TRIANGLES (vector-ref ground 6))
  (for-each (lambda (om)
              (bind-upload! prog (car om))
              (each (car om) (cdr om))
              (cmd-draw-elements! GL-TRIANGLES
                                  (vector-ref (car om) 6)))
            models))

(define (pass! q tgt setup)
  (if tgt (fx-bind-target! tgt) (fx-bind-canvas!))
  (fx-fullscreen-use! q 0.0)
  (setup (fx-quad-program q))
  (fx-fullscreen-draw! q))

(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   ;; last frame's composite left our targets on these units
   (cmd-unbind-texture! 0)
   (cmd-unbind-texture! 1)
   (let* ((a (fl* 0.12 t))
          (eye (v3 (fl* 14.0 (flsin a)) 7.5 (fl* 14.0 (flcos a))))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 1.5 0.0)
                                       (v3 0.0 1.0 0.0)))))
     ;; the lit scene
     (fx-bind-target! scene-t)
     (cmd-clear! 0.72 0.78 0.86 1.0)
     (draw-scene! lit-p
                  (lambda (obj m)
                    (fx-uniform! lit-p 'u_mvp (m4-mul vp m))
                    (fx-uniform! lit-p 'u_model m)
                    (fx-uniform! lit-p 'u_light (v3-x light)
                                 (v3-y light) (v3-z light))
                    (fx-uniform! lit-p 'u_ambient 0.45)
                    (fx-uniform! lit-p 'u_color 0.82 0.8 0.76 1.0)))
     ;; linear depth
     (fx-bind-target! depth-t)
     (cmd-clear! 1.0 1.0 1.0 1.0)
     (draw-scene! depth-p
                  (lambda (obj m)
                    (fx-uniform! depth-p 'u_mvp (m4-mul vp m))
                    (fx-uniform! depth-p 'u_eye (v3-x eye)
                                 (v3-y eye) (v3-z eye))
                    (fx-uniform! depth-p 'u_far FAR)))
     (cmd-depth! #f)
     ;; occlusion, blur, composite
     (pass! ssao-q ao-t
            (lambda (p)
              (cmd-bind-texture! 0 (fx-target-texture depth-t))
              (fx-uniform! p 'u_g 0)
              (fx-uniform! p 'u_texel (fl/ 1.0 400.0) (fl/ 1.0 300.0))))
     (pass! blur-q blur-t
            (lambda (p)
              (cmd-bind-texture! 0 (fx-target-texture ao-t))
              (fx-uniform! p 'u_src 0)
              (fx-uniform! p 'u_texel (fl/ 1.0 400.0) (fl/ 1.0 300.0))))
     (pass! comp-q #f
            (lambda (p)
              (cmd-bind-texture! 0 (fx-target-texture scene-t))
              (cmd-bind-texture! 1 (fx-target-texture blur-t))
              (fx-uniform! p 'u_scene 0)
              (fx-uniform! p 'u_ao 1)
              (fx-uniform! p 'u_texel
                           (fl/ 1.0 800.0) (fl/ 1.0 600.0)))))))
