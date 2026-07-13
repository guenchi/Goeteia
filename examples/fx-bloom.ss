;; Bloom, the classic post chain: the scene renders offscreen, a
;; threshold pass keeps only the bright pixels (at half resolution --
;; blur cost drops 4x and the result only gets softer), a separable
;; gaussian ping-pongs horizontal/vertical twice, and the composite
;; adds the glow back over the scene.  Five passes, one command
;; buffer.  Needs WebGL 2.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

(define scene-prog (fx-program! mesh-lit-vs mesh-lit-fs))
(define scene (fx-target-hdr! 800 600))  ; half-float: >1 survives
(define bright (fx-target! 400 300))
(define blur-a (fx-target! 400 300))
(define blur-b (fx-target! 400 300))

;; pass 2: keep what shines.  smoothstep over luminance, so the
;; cutoff has no hard edge of its own
(define bright-q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform sampler2D u_scene)
     (uniform vec2 u_texel)              ; 1/target-size
     (define (main) void
       (local vec2 uv (* gl_FragCoord.xy u_texel))
       (local vec4 c (texture2D u_scene uv))
       (local float l (dot c.rgb (vec3 "0.2126" "0.7152" "0.0722")))
       ;; a true HDR threshold: only what shines past white blooms
       (set! gl_FragColor
             (vec4 (* c.rgb (smoothstep "1.02" "1.9" l)) (fl 1)))))))

;; passes 3+4 (twice): one gaussian shader, the axis in u_dir
(define blur-q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform sampler2D u_src)
     (uniform vec2 u_texel)
     (uniform vec2 u_dir)                ; (1,0) or (0,1)
     (define (tap (vec2 uv) (float o) (float w)) vec3
       (local vec4 c (texture2D u_src (+ uv (* (* u_dir u_texel) o))))
       (return (* c.rgb w)))
     (define (main) void
       (local vec2 uv (* gl_FragCoord.xy u_texel))
       (local vec3 acc (tap uv (fl 0) "0.227027"))
       (set! acc (+ acc (tap uv (fl 1) "0.1945946")))
       (set! acc (+ acc (tap uv (- (fl 1)) "0.1945946")))
       (set! acc (+ acc (tap uv (fl 2) "0.1216216")))
       (set! acc (+ acc (tap uv (- (fl 2)) "0.1216216")))
       (set! acc (+ acc (tap uv (fl 3) "0.054054")))
       (set! acc (+ acc (tap uv (- (fl 3)) "0.054054")))
       (set! acc (+ acc (tap uv (fl 4) "0.016216")))
       (set! acc (+ acc (tap uv (- (fl 4)) "0.016216")))
       (set! gl_FragColor (vec4 acc (fl 1)))))))

;; pass 5: the scene plus its glow
(define comp-q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform sampler2D u_scene)
     (uniform sampler2D u_bloom)
     (uniform vec2 u_texel)
     (define (main) void
       (local vec2 uv (* gl_FragCoord.xy u_texel))
       (local vec4 c (texture2D u_scene uv))
       (local vec4 b (texture2D u_bloom uv))
       (local vec3 one (vec3 (fl 1) (fl 1) (fl 1)))
       (local vec3 sum (+ c.rgb (* b.rgb "1.1")))
       ;; extended Reinhard: lows pass, highs roll off toward white
       (set! sum (* sum (/ (+ one (/ sum "9.0")) (+ one sum))))
       (set! gl_FragColor (vec4 sum (fl 1)))))))

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

(define (blur! src dst dx dy)
  (fx-bind-target! dst)
  (fx-fullscreen-use! blur-q 0.0)
  (cmd-bind-texture! 0 (fx-target-texture src))
  (let ((p (fx-quad-program blur-q)))
    (fx-uniform! p 'u_src 0)
    (fx-uniform! p 'u_texel (fl/ 1.0 400.0) (fl/ 1.0 300.0))
    (fx-uniform! p 'u_dir dx dy))
  (fx-fullscreen-draw! blur-q))

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
   ;; pass 2: threshold, at half resolution
   (fx-bind-target! bright)
   (fx-fullscreen-use! bright-q t)
   (cmd-bind-texture! 0 (fx-target-texture scene))
   (fx-uniform! (fx-quad-program bright-q) 'u_scene 0)
   (fx-uniform! (fx-quad-program bright-q) 'u_texel
                (fl/ 1.0 400.0) (fl/ 1.0 300.0))
   (fx-fullscreen-draw! bright-q)
   ;; passes 3+4, twice: the gaussian ping-pong
   (blur! bright blur-a 1.0 0.0)
   (blur! blur-a blur-b 0.0 1.0)
   (blur! blur-b blur-a 1.0 0.0)
   (blur! blur-a blur-b 0.0 1.0)
   ;; pass 5: composite to the canvas
   (fx-bind-canvas!)
   (fx-fullscreen-use! comp-q t)
   (cmd-bind-texture! 0 (fx-target-texture scene))
   (cmd-bind-texture! 1 (fx-target-texture blur-b))
   (let ((p (fx-quad-program comp-q)))
     (fx-uniform! p 'u_scene 0)
     (fx-uniform! p 'u_bloom 1)
     (fx-uniform! p 'u_texel (fl/ 1.0 800.0) (fl/ 1.0 600.0)))
   (fx-fullscreen-draw! comp-q)))
