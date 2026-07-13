;; Shadow mapping in two passes -- soft, the PCSS way.  Pass 1
;; renders the casters from the light's point of view into a
;; depth-only fx-target (no color buffer at all).  Pass 2 renders
;; the scene normally; each fragment reprojects itself into light
;; space and asks the map in three steps: a blocker search averages
;; the depths that occlude it, the penumbra width follows from how
;; far behind them it sits (an area light's similar triangles), and
;; a PCF whose radius IS that width does the test.  Shadows harden
;; at contact and melt with distance -- watch the hovering box
;; against the sitting one.  Needs WebGL 2.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

;; ---- pass 1: depth only, from the light ----
;; a_normal is declared (unused) so the stride matches the shared
;; pos+normal vertex stream; the linker keeps our forced locations.
(define depth-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 1) (fl 1) (fl 1) (fl 1)))))))

;; ---- pass 2: lit, sampling the shadow map ----
(define lit-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)                ; camera VP * model
     (uniform mat4 u_model)
     (uniform mat4 u_light_mvp)          ; light VP * model
     (varying vec3 v_normal)
     (varying vec4 v_shadow)
     (define (main) void
       (local vec4 p (vec4 a_pos (fl 1)))
       (set! gl_Position (* u_mvp p))
       (set! v_shadow (* u_light_mvp p))
       (set! v_normal (* (mat3 u_model) a_normal))))
   '((precision mediump float)
     (uniform sampler2D u_shadow)
     (uniform vec3 u_light)              ; unit vector toward the light
     (uniform vec4 u_color)
     (uniform vec2 u_texel)              ; 1/shadow-map-size
     (uniform float u_lightsize)         ; the area light, in map depth
     (varying vec3 v_normal)
     (varying vec4 v_shadow)
     (define (main) void
       ;; light-space NDC -> [0,1] texture/depth coordinates
       (local vec3 sp (+ (* (/ v_shadow.xyz v_shadow.w) (fl 0 50))
                         (vec3 (fl 0 50) (fl 0 50) (fl 0 50))))
       (local float lit (fl 1))
       ;; 1. blocker search: what occludes this fragment, on average?
       (local float bsum (fl 0))
       (local float bcnt (fl 0))
       (for (int x -2 (< x 3) (+ x 1))
         (for (int y -2 (< y 3) (+ y 1))
           (local vec4 sv (texture2D u_shadow
                                     (+ sp.xy (* (vec2 x y)
                                                 (* u_texel "3.0")))))
           (local float isb (step sv.r (- sp.z "0.002")))
           (set! bsum (+ bsum (* sv.r isb)))
           (set! bcnt (+ bcnt isb))))
       (if (> bcnt (fl 0 50))
           ;; 2. similar triangles: penumbra grows with the gap
           ;; between receiver and average blocker (in texels)...
           (local float zb (/ bsum bcnt))
           (local float rad (clamp (* (/ (- sp.z zb) zb) u_lightsize)
                                   "1.0" "9.0"))
           ;; 3. ...and a PCF that wide does the actual test
           (local float acc (fl 0))
           (for (int x -2 (< x 3) (+ x 1))
             (for (int y -2 (< y 3) (+ y 1))
               (local vec4 s2 (texture2D u_shadow
                                         (+ sp.xy (* (vec2 x y)
                                                     (* u_texel
                                                        (* rad (fl 0 50)))))))
               (set! acc (+ acc (step (- sp.z "0.002") s2.r)))))
           (set! lit (/ acc "25.0")))
       (local float d (max (dot (normalize v_normal) u_light) (fl 0)))
       (set! gl_FragColor
             (vec4 (* u_color.rgb (+ (fl 0 25) (* (fl 0 75) (* d lit))))
                   u_color.a))))))

;; ---- geometry: a ground plane and one shared box ----
(define ground (mesh-plane 30.0 30.0))
(define box (mesh-box 2.0 2.0 2.0))
(define gvbuf (fx-buffer!))
(define gibuf (fx-buffer!))
(define bvbuf (fx-buffer!))
(define bibuf (fx-buffer!))
(define gvbase (fx-alloc! (mesh-vertex-bytes ground)))
(define gibase (fx-alloc! (mesh-index-bytes ground)))
(define bvbase (fx-alloc! (mesh-vertex-bytes box)))
(define bibase (fx-alloc! (mesh-index-bytes box)))
(mesh-write! ground gvbase gibase)
(mesh-write! box bvbase bibase)

;; ---- the shadow map: 1024x1024 of pure depth ----
(define shadow-t (fx-target! 1024 1024 #t))

;; the light: direction, and an orthographic view down that direction
(define light (v3-normalize (v3 0.55 1.0 0.4)))
(define light-vp
  (m4-mul (m4-ortho -16.0 16.0 -16.0 16.0 1.0 45.0)
          (m4-look-at (v3-scale light 24.0) (v3 0.0 0.0 0.0)
                      (v3 0.0 1.0 0.0))))

(define proj (m4-perspective 1.0 (/ 800.0 600.0) 0.1 100.0))
(define uploaded #f)

;; the casters move; their model matrices rebuild each frame
(define (box-models t)
  (list (m4-translate -4.0 1.0 -2.0)                       ; sitting
        (m4-mul (m4-translate 3.5 5.0 1.0) (m4-rotate-y t)) ; hovering high
        (m4-mul (m4-translate (fl* 7.0 (flsin (fl* 0.6 t)))
                              1.0
                              (fl* 7.0 (flcos (fl* 0.6 t))))
                (m4-rotate-y (fl* 2.0 t)))))               ; orbiting

(define (draw-boxes! prog models each)
  (fx-use! prog bvbuf)
  (cmd-bind-index! bibuf)
  (for-each (lambda (m)
              (each m)
              (cmd-draw-elements! GL-TRIANGLES (mesh-index-count box)))
            models))

(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   (unless uploaded
     (cmd-bind-buffer! gvbuf) (cmd-buffer-data! gvbase
                                                (mesh-vertex-bytes ground))
     (cmd-bind-index! gibuf) (cmd-index-data! gibase
                                              (mesh-index-bytes ground))
     (cmd-bind-buffer! bvbuf) (cmd-buffer-data! bvbase
                                                (mesh-vertex-bytes box))
     (cmd-bind-index! bibuf) (cmd-index-data! bibase (mesh-index-bytes box))
     (set! uploaded #t))
   (let ((models (box-models t)))
     ;; pass 1: casters only, from the light (the ground only receives)
     (cmd-unbind-texture! 0)           ; the map was sampled last frame
     (fx-bind-target! shadow-t)
     (cmd-clear! 1.0 1.0 1.0 1.0)
     (draw-boxes! depth-p models
                  (lambda (m)
                    (fx-uniform! depth-p 'u_mvp (m4-mul light-vp m))))
     ;; pass 2: the scene, asking the shadow map who is lit
     (fx-bind-canvas!)
     (cmd-clear! 0.09 0.11 0.16 1.0)
     (let* ((a (fl* 0.3 t))
            (eye (v3 (fl* 20.0 (flsin a)) 11.0 (fl* 20.0 (flcos a))))
            (vp (m4-mul proj (m4-look-at eye (v3 0.0 1.0 0.0)
                                         (v3 0.0 1.0 0.0))))
            (unis! (lambda (m r g b)
                     (fx-uniform! lit-p 'u_mvp (m4-mul vp m))
                     (fx-uniform! lit-p 'u_model m)
                     (fx-uniform! lit-p 'u_light_mvp (m4-mul light-vp m))
                     (fx-uniform! lit-p 'u_color r g b 1.0))))
       ;; the ground
       (fx-use! lit-p gvbuf)
       (cmd-bind-index! gibuf)
       (cmd-bind-texture! 0 (fx-target-texture shadow-t))
       (fx-uniform! lit-p 'u_shadow 0)
       (fx-uniform! lit-p 'u_light (v3-x light) (v3-y light) (v3-z light))
       (fx-uniform! lit-p 'u_texel (fl/ 1.0 1024.0) (fl/ 1.0 1024.0))
       (fx-uniform! lit-p 'u_lightsize 400.0)
       (unis! (m4-identity) 0.35 0.4 0.45)
       (cmd-draw-elements! GL-TRIANGLES (mesh-index-count ground))
       ;; the boxes, shadowing each other too
       (draw-boxes! lit-p models
                    (lambda (m) (unis! m 0.9 0.55 0.3)))))))
