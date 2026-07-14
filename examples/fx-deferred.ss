;; Deferred shading over a multi render target: the scene rasterizes
;; ONCE into a G-buffer -- albedo, world normal and world position,
;; three half-float attachments behind one framebuffer, filled by one
;; fragment shader with (out 0/1/2 ...) forms (fx-program3!) -- and
;; then 24 moving point lights cost one fullscreen pass, not 24
;; scene traversals.  Lighting price stops depending on scene
;; complexity: the classic trade.  Needs WebGL 2.
(import (rnrs) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx post) (gfx stats))

(fx-init! (get-element-by-id "c"))

;; ---- pass 1: geometry into the G-buffer (ESSL 3.00, MRT) ----
(define geo-p
  (fx-program3!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (varying vec3 v_normal)
     (varying vec3 v_pos)
     (define (main) void
       (local vec4 w (* u_model (vec4 a_pos (fl 1))))
       (set! v_pos w.xyz)
       (set! v_normal (vec3 (* u_model (vec4 a_normal (fl 0)))))
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))))
   '((precision mediump float)
     (uniform vec4 u_albedo)
     (uniform float u_reflect)           ; rides o_normal.w for SSR
     (varying vec3 v_normal)
     (varying vec3 v_pos)
     (out 0 vec4 o_albedo)
     (out 1 vec4 o_normal)
     (out 2 vec4 o_pos)
     (define (main) void
       ;; albedo arrives sRGB; the light math downstream is linear
       (set! o_albedo (vec4 (pow u_albedo.rgb (vec3 "2.2" "2.2" "2.2"))
                            u_albedo.a))
       (set! o_normal (vec4 (normalize v_normal) u_reflect))
       ;; w = 1 marks a covered pixel; the clear leaves 0 behind
       (set! o_pos (vec4 v_pos (fl 1)))))))

;; ---- pass 2: every light, one fullscreen quad ----
;; light positions and colors are derived from the loop index, so
;; the whole rig is three texture reads plus arithmetic
(define light-q
  (fx-fullscreen!
   '((precision mediump float)
     (uniform sampler2D u_albedo)
     (uniform sampler2D u_normal)
     (uniform sampler2D u_pos)
     (uniform vec2 u_resolution)
     (uniform float u_time)
     (define (main) void
       (local vec2 uv (/ gl_FragCoord.xy u_resolution))
       (local vec4 alb (texture2D u_albedo uv))
       (local vec4 nrm (texture2D u_normal uv))
       (local vec4 ps (texture2D u_pos uv))
       (if-else (< ps.w (fl 0 50))
         ((set! gl_FragColor (vec4 "0.03" "0.04" "0.06" (fl 1))))
         ((local vec3 n (normalize nrm.xyz))
          (local vec3 acc (* alb.rgb "0.05"))    ; a whisper of ambient
          (for (int i 0 (< i 24) (+ i 1))
            (local float fi (float i))
            ;; each light orbits at its own radius, height and speed
            (local float ang (+ (* u_time (+ "0.3" (* "0.021" fi)))
                                (* fi "2.61799")))
            (local float rad (+ "2.5" (* "8.5" (fract (* fi "0.618034")))))
            (local vec3 lp (vec3 (* rad (cos ang))
                                 (+ "0.7" (* "1.8" (fract (* fi "0.382"))))
                                 (* rad (sin ang))))
            (local vec3 lc (+ (vec3 "0.5" "0.5" "0.5")
                              (* "0.5" (cos (+ (* (vec3 "1.0" "0.7" "0.4") fi)
                                               (vec3 (fl 0) (fl 2) (fl 4)))))))
            (local vec3 dv (- lp ps.xyz))
            (local float d2 (dot dv dv))
            (local float att (* (/ "1.6" (+ (fl 1) (* "0.35" d2)))
                                (max (- (fl 1) (* d2 "0.018")) (fl 0))))
            (local float nl (max (dot n (normalize dv)) (fl 0)))
            (set! acc (+ acc (* (* alb.rgb lc) (* nl att)))))
          (set! gl_FragColor (vec4 acc (fl 1)))))))))

;; ---- pass 3: screen-space reflections over the lit result ----
;; march the reflected eye ray through world space, reproject each
;; step through u_vp, and compare its distance-from-eye against the
;; G-buffer's -- the first step that lands behind geometry is the
;; hit, and its lit color tints the surface by o_normal.w
(define ssr-q
  (fx-fullscreen!
   '((precision highp float)
     (uniform sampler2D u_scene)
     (uniform sampler2D u_normal)
     (uniform sampler2D u_pos)
     (uniform vec2 u_resolution)
     (uniform mat4 u_vp)
     (uniform vec3 u_eye)
     (define (main) void
       (local vec2 uv (/ gl_FragCoord.xy u_resolution))
       (local vec4 sc (texture2D u_scene uv))
       (local vec4 nrm (texture2D u_normal uv))
       (local vec4 ps (texture2D u_pos uv))
       (local vec3 outc sc.rgb)
       (if (> (* ps.w nrm.w) "0.01")
           (local vec3 n (normalize nrm.xyz))
           (local vec3 v (normalize (- ps.xyz u_eye)))
           (local vec3 rd (normalize (reflect v n)))
           (local vec3 hit (vec3 (fl 0) (fl 0) (fl 0)))
           (local float found (fl 0))
           (for (int i 1 (< i 25) (+ i 1))
             (local vec3 sp (+ ps.xyz (* rd (* (float i) "0.35"))))
             (local vec4 clip (* u_vp (vec4 sp (fl 1))))
             (local vec3 ndc (/ clip.xyz clip.w))
             (local vec2 suv (+ (* ndc.xy (fl 0 50))
                                (vec2 (fl 0 50) (fl 0 50))))
             (local float inb (* (* (step (fl 0) suv.x)
                                    (step suv.x (fl 1)))
                                 (* (step (fl 0) suv.y)
                                    (step suv.y (fl 1)))))
             (local vec4 gp (texture2D u_pos suv))
             (local float dray (distance sp u_eye))
             (local float dsc (distance gp.xyz u_eye))
             ;; behind geometry, but not by more than a step
             (local float hitnow (* (* inb gp.w)
                                    (* (step dsc dray)
                                       (step (- dray dsc) "0.7"))))
             (set! hitnow (* hitnow (- (fl 1) found)))
             (if (> hitnow (fl 0 50))
                 (local vec4 hc (texture2D u_scene suv))
                 (set! hit hc.rgb)
                 (set! found (fl 1))))
           ;; grazing angles reflect harder (Schlick-ish)
           (local float fres (+ (fl 0 30)
                                (* (fl 0 70)
                                   (pow (- (fl 1)
                                           (max (dot (- v) n) (fl 0)))
                                        (fl 2)))))
           (set! outc (mix sc.rgb hit (* (* found nrm.w) fres))))
       (set! gl_FragColor (vec4 outc sc.a))))))

;; ---- geometry ----

(define ground (fx-mesh! (mesh-plane 30.0 30.0)))
(define torus (fx-mesh! (mesh-torus 1.1 0.42 28 14)))
(define ball (fx-mesh! (mesh-sphere 0.9 28 14)))

;; a 4x4 field of alternating toruses and spheres to catch the light
(define models
  (let row ((i 0) (acc '()))
    (if (= i 4)
        acc
        (let col ((j 0) (acc acc))
          (if (= j 4)
              (row (+ i 1) acc)
              (let* ((x (fl* 5.0 (fl- (fixnum->flonum j) 1.5)))
                     (z (fl* 5.0 (fl- (fixnum->flonum i) 1.5)))
                     (tor? (= 0 (remainder (+ i j) 2))))
                (col (+ j 1)
                     (cons (vector (if tor? torus ball)
                                   (if tor?
                                       (m4-mul (m4-translate x 1.1 z)
                                               (m4-rotate-x 1.5707963))
                                       (m4-translate x 0.9 z))
                                   (vector (fl+ 0.35 (fl* 0.15 (fixnum->flonum j)))
                                           0.55
                                           (fl+ 0.35 (fl* 0.15 (fixnum->flonum i)))))
                           acc))))))))

(define gbuf (fx-target-mrt! 3 800 600))
;; the lights accumulate in real HDR; grade tonemaps (ACES) and
;; gamma-encodes, FXAA smooths the result onto the canvas
(define hdr (fx-target-hdr! 800 600))
(define hdr2 (fx-target-hdr! 800 600))  ; after reflections
(define ldr (fx-target! 800 600))
(define grade (make-grade))
(define fxaa (make-fxaa))
(define hud (make-stats))               ; ms / fps / draws / bytes
(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.5 80.0))

(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   ;; last frame's light pass left the G-buffer on these units
   (cmd-unbind-texture! 0)
   (cmd-unbind-texture! 1)
   (cmd-unbind-texture! 2)
   (let* ((a (fl* 0.1 t))
          (eye (v3 (fl* 15.0 (flsin a)) 8.5 (fl* 15.0 (flcos a))))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 0.5 0.0)
                                       (v3 0.0 1.0 0.0)))))
     ;; geometry: one traversal fills all three attachments
     (fx-bind-target! gbuf)
     (cmd-clear! 0.0 0.0 0.0 0.0)
     (fx-mesh-use! geo-p ground)
     (fx-uniform! geo-p 'u_mvp vp)
     (fx-uniform! geo-p 'u_model (m4-identity))
     (fx-uniform! geo-p 'u_albedo 0.42 0.44 0.48 1.0)
     (fx-uniform! geo-p 'u_reflect 0.6)  ; the floor is polished
     (fx-mesh-draw! ground)
     (fx-uniform! geo-p 'u_reflect 0.1)
     (for-each
      (lambda (om)
        (let ((obj (vector-ref om 0))
              (m (vector-ref om 1))
              (c (vector-ref om 2)))
          (fx-mesh-use! geo-p obj)
          (fx-uniform! geo-p 'u_mvp (m4-mul vp m))
          (fx-uniform! geo-p 'u_model m)
          (fx-uniform! geo-p 'u_albedo (vector-ref c 0)
                       (vector-ref c 1) (vector-ref c 2) 1.0)
          (fx-mesh-draw! obj)))
      models)
     ;; lights: one quad, whatever the scene weighed
     (cmd-depth! #f)
     (fx-bind-target! hdr)
     (fx-fullscreen-use! light-q t)
     (cmd-bind-texture! 0 (fx-mrt-texture gbuf 0))
     (cmd-bind-texture! 1 (fx-mrt-texture gbuf 1))
     (cmd-bind-texture! 2 (fx-mrt-texture gbuf 2))
     (let ((p (fx-quad-program light-q)))
       (fx-uniform! p 'u_albedo 0)
       (fx-uniform! p 'u_normal 1)
       (fx-uniform! p 'u_pos 2))
     (fx-fullscreen-draw! light-q)
     ;; reflections: march the lit image against the G-buffer
     (fx-bind-target! hdr2)
     (fx-fullscreen-use! ssr-q t)
     (cmd-bind-texture! 0 (fx-target-texture hdr))
     (cmd-bind-texture! 1 (fx-mrt-texture gbuf 1))
     (cmd-bind-texture! 2 (fx-mrt-texture gbuf 2))
     (let ((p (fx-quad-program ssr-q)))
       (fx-uniform! p 'u_scene 0)
       (fx-uniform! p 'u_normal 1)
       (fx-uniform! p 'u_pos 2)
       (fx-uniform! p 'u_vp vp)
       (fx-uniform! p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye)))
     (fx-fullscreen-draw! ssr-q)
     ;; tonemap, then anti-alias, onto the canvas
     (grade-run! grade (fx-target-texture hdr2) ldr 'aces 1.3 800 600)
     (fxaa-run! fxaa (fx-target-texture ldr) #f 800 600)
     (stats-draw! hud dt))))
