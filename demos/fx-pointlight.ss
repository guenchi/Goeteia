;; Point-light shadows over a mirror floor.  A light in the middle of
;; the room casts in every direction at once, so the shadow map is a
;; cube -- six half-float faces (fx-cube-target!) each holding the
;; distance from the light to whatever it sees.  The floor is polished
;; black: a second camera, mirrored about the floor plane, renders the
;; pillars and the bulb upside down into a texture, and each floor
;; fragment projects itself through that camera and Fresnel-blends the
;; reflection over its own shadowed stone -- so the pillars stand in
;; the floor, and the bulb drags a hot streak beneath itself.
;; Needs WebGL 2.
(import (rnrs) (web sx) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh))

;; the demo mounts its own canvas where the hero usually lives
(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero"))
        (canvas (@ (id "c") (width "720") (height "400")
                   (style "display:block;width:100%;max-width:40em;border-radius:12px"))))))

(fx-init! (get-element-by-id "c"))

(define FAR 40.0)

;; pass 1 (x6): distance from the light, into a cube face
(define dist-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (varying vec3 v_wp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_wp (vec3 (* u_model (vec4 a_pos (fl 1)))))))
   '((precision mediump float)
     (uniform vec3 u_lpos)
     (uniform float u_far)
     (varying vec3 v_wp)
     (define (main) void
       (set! gl_FragColor
             (vec4 (/ (distance v_wp u_lpos) u_far)
                   (fl 0) (fl 0) (fl 1)))))))

;; pass 2: point light with attenuation, shadowed by the cube
(define lit-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (varying vec3 v_wp)
     (varying vec3 v_n)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_wp (vec3 (* u_model (vec4 a_pos (fl 1)))))
       (set! v_n (* (mat3 u_model) a_normal))))
   '((precision mediump float)
     (uniform samplerCube u_shadow)
     (uniform vec3 u_lpos)
     (uniform float u_far)
     (uniform vec4 u_color)
     (varying vec3 v_wp)
     (varying vec3 v_n)
     (define (main) void
       (local vec3 dv (- v_wp u_lpos))
       (local float dist (length dv))
       (local float dn (/ dist u_far))
       (local vec4 sv (textureCube u_shadow dv))
       (local float lit (step (- dn "0.01") sv.r))
       (local vec3 l (normalize (- dv)))   ; toward the light
       (local float diff (max (dot (normalize v_n) l) (fl 0)))
       (local float atten (/ (fl 1) (+ (fl 1) (* "0.015"
                                                  (* dist dist)))))
       (local vec3 base (pow u_color.rgb (vec3 "2.2" "2.2" "2.2")))
       (local vec3 c (* base (+ "0.06"
                                (* (* (* diff lit) atten) "2.4"))))
       (set! gl_FragColor
             (vec4 (pow c (vec3 "0.4545" "0.4545" "0.4545"))
                   u_color.a))))))

;; the bulb itself: unlit, it IS the light
(define glow-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))))
   '((precision mediump float)
     (define (main) void
       (set! gl_FragColor (vec4 (fl 1) "0.95" "0.8" (fl 1)))))))

;; the floor: the same shadowed point light over dark stone, then the
;; mirrored world projected back down and blended in by Fresnel --
;; grazing views turn to mirror, steep ones keep the stone (and its
;; sweeping shadows)
(define floor-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_rvp)                ; the reflection camera's VP
     (varying vec3 v_wp)
     (varying vec4 v_rclip)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_wp a_pos)                 ; the floor sits at the origin
       (set! v_rclip (* u_rvp (vec4 a_pos (fl 1))))))
   '((precision mediump float)
     (uniform samplerCube u_shadow)
     (uniform sampler2D u_refl)
     (uniform vec3 u_lpos)
     (uniform vec3 u_eye)
     (uniform float u_far)
     (varying vec3 v_wp)
     (varying vec4 v_rclip)
     (define (main) void
       ;; the same shadow test the pillars run, normal pinned to +y
       (local vec3 dv (- v_wp u_lpos))
       (local float dist (length dv))
       (local float dn (/ dist u_far))
       (local vec4 sv (textureCube u_shadow dv))
       (local float lit (step (- dn "0.01") sv.r))
       (local vec3 l (normalize (- dv)))
       (local float diff (max l.y (fl 0)))
       (local float atten (/ (fl 1) (+ (fl 1) (* "0.015"
                                                  (* dist dist)))))
       (local vec3 base (pow (vec3 "0.30" "0.30" "0.34")
                             (vec3 "2.2" "2.2" "2.2")))
       (local vec3 c (* base (+ "0.06"
                                (* (* (* diff lit) atten) "2.4"))))
       (local vec3 fc (pow c (vec3 "0.4545" "0.4545" "0.4545")))
       ;; where the mirrored camera saw this spot
       (local vec2 uv (+ (* (/ v_rclip.xy v_rclip.w) (fl 0 50))
                         (vec2 (fl 0 50) (fl 0 50))))
       (local vec4 refl (texture2D u_refl uv))
       ;; flat views mirror the room, steep ones see the stone
       (local vec3 v (normalize (- u_eye v_wp)))
       (local float f (+ (fl 0 30)
                         (* (fl 0 60)
                            (pow (- (fl 1) (max v.y (fl 0)))
                                 (fl 3)))))
       (set! gl_FragColor (vec4 (mix fc refl.rgb f) (fl 1)))))))

;; ---- geometry ----
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

(define floor-obj (upload (mesh-plane 70.0 70.0)))
(define pillar (upload (mesh-box 1.4 7.0 1.4)))
(define bulb (upload (mesh-sphere 0.5 16 8)))

(define pillar-models
  (let ring ((k 0) (acc '()))
    (if (= k 10)
        acc
        (let ((a (fl* 0.6283185307179586 (fixnum->flonum k))))
          (ring (+ k 1)
                (cons (m4-translate (fl* 13.0 (flsin a)) 3.5
                                    (fl* 13.0 (flcos a)))
                      acc))))))

(define cube-t (fx-cube-target! 512))
;; the room, as the floor sees it -- full resolution and 4x MSAA,
;; or the mirrored pillars come out in staircase edges
(define refl (fx-target-msaa! 720 400 4))

;; the six views out of the light, GL cube-face conventions
(define face-proj (m4-perspective 1.5707963267948966 1.0 0.1 FAR))
(define (face-vp p i)
  (define (look dx dy dz ux uy uz)
    (m4-mul face-proj
            (m4-look-at p (v3-add p (v3 dx dy dz)) (v3 ux uy uz))))
  (case i
    ((0) (look 1.0 0.0 0.0   0.0 -1.0 0.0))
    ((1) (look -1.0 0.0 0.0  0.0 -1.0 0.0))
    ((2) (look 0.0 1.0 0.0   0.0 0.0 1.0))
    ((3) (look 0.0 -1.0 0.0  0.0 0.0 -1.0))
    ((4) (look 0.0 0.0 1.0   0.0 -1.0 0.0))
    (else (look 0.0 0.0 -1.0 0.0 -1.0 0.0))))

(define proj (m4-perspective 0.9 (/ 720.0 400.0) 0.5 200.0))

(define (draw-pillars! prog each)
  (bind-upload! prog pillar)
  (for-each (lambda (m)
              (each m)
              (cmd-draw-elements! GL-TRIANGLES (vector-ref pillar 6)))
            pillar-models))

;; the pillars and the bulb, from any camera -- once upside down into
;; the reflection target, once onto the canvas
(define (draw-scene! vp lp)
  (bind-upload! lit-p pillar)
  (cmd-bind-cubemap! 0 (fx-target-texture cube-t))
  (fx-uniform! lit-p 'u_shadow 0)
  (fx-uniform! lit-p 'u_lpos (v3-x lp) (v3-y lp) (v3-z lp))
  (fx-uniform! lit-p 'u_far FAR)
  (draw-pillars! lit-p
                 (lambda (m)
                   (fx-uniform! lit-p 'u_mvp (m4-mul vp m))
                   (fx-uniform! lit-p 'u_model m)
                   (fx-uniform! lit-p 'u_color 0.7 0.55 0.4 1.0)))
  ;; the bulb, small and hot
  (bind-upload! glow-p bulb)
  (fx-uniform! glow-p 'u_mvp
               (m4-mul vp (m4-translate (v3-x lp) (v3-y lp)
                                        (v3-z lp))))
  (cmd-draw-elements! GL-TRIANGLES (vector-ref bulb 6)))

(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   (let* ((lp (v3 (fl* 5.0 (flsin (fl* 0.7 t)))
                  (fl+ 4.5 (fl* 2.0 (flsin (fl* 1.3 t))))
                  (fl* 5.0 (flcos (fl* 0.7 t)))))
          (a (fl* 0.1 t))
          (eye (v3 (fl* 26.0 (flsin a)) 12.0 (fl* 26.0 (flcos a))))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 2.0 0.0)
                                       (v3 0.0 1.0 0.0))))
          ;; the same camera mirrored about the floor plane (y = 0)
          (meye (v3 (v3-x eye) (fl- 0.0 (v3-y eye)) (v3-z eye)))
          (rvp (m4-mul proj (m4-look-at meye (v3 0.0 -2.0 0.0)
                                        (v3 0.0 1.0 0.0)))))
     ;; unbind first: rendering into targets still bound for sampling
     ;; is a feedback loop Chrome rejects on every draw
     (cmd-unbind-cubemap! 0)
     (cmd-unbind-texture! 1)
     ;; six distance passes out of the light
     (let face ((i 0))
       (when (< i 6)
         (fx-bind-cube-face! cube-t i)
         (cmd-clear! 1.0 1.0 1.0 1.0)
         (let ((fvp (face-vp lp i)))
           (draw-pillars! dist-p
                          (lambda (m)
                            (fx-uniform! dist-p 'u_mvp (m4-mul fvp m))
                            (fx-uniform! dist-p 'u_model m)
                            (fx-uniform! dist-p 'u_lpos (v3-x lp)
                                         (v3-y lp) (v3-z lp))
                            (fx-uniform! dist-p 'u_far FAR))))
         (face (+ i 1))))
     ;; the room upside down: what the floor will reflect
     (fx-bind-target! refl)
     (cmd-clear! 0.03 0.03 0.05 1.0)
     (draw-scene! rvp lp)
     (fx-resolve! refl)                 ; msaa samples -> the texture
     ;; the room itself, standing on its own reflection
     (fx-bind-canvas!)
     (cmd-clear! 0.03 0.03 0.05 1.0)
     (bind-upload! floor-p floor-obj)
     (cmd-bind-cubemap! 0 (fx-target-texture cube-t))
     (cmd-bind-texture! 1 (fx-target-texture refl))
     (fx-uniform! floor-p 'u_shadow 0)
     (fx-uniform! floor-p 'u_refl 1)
     (fx-uniform! floor-p 'u_lpos (v3-x lp) (v3-y lp) (v3-z lp))
     (fx-uniform! floor-p 'u_far FAR)
     (fx-uniform! floor-p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye))
     (fx-uniform! floor-p 'u_mvp vp)
     (fx-uniform! floor-p 'u_rvp rvp)
     (cmd-draw-elements! GL-TRIANGLES (vector-ref floor-obj 6))
     (draw-scene! vp lp))))
