;; Water: an island and its reflection.  Pass 1 renders the island
;; from the camera mirrored about the water plane (fragments below
;; the surface discard -- the poor man's clip plane) into an
;; offscreen target; pass 2 draws the scene, then the water samples
;; that texture at its own position in the *reflection* camera's
;; clip space, ripples the lookup with moving sines, and blends
;; toward the reflection by a Fresnel term.  All existing parts.
(import (rnrs) (web js) (web dom) (web gl) (web glsl) (web fx)
        (web mat) (web mesh))

(fx-init! (get-element-by-id "c"))

;; the island: rolling hills scaled by a radial falloff, shoreline
;; dipping below the water at y=0
(define (island x z)
  (let* ((r2 (fl+ (fl* x x) (fl* z z)))
         (fall (fl- 1.0 (fl/ r2 2500.0)))
         (fall (if (fl<? fall 0.0) 0.0 fall)))
    (fl- (fl* fall
              (fl+ (fl* 7.0 (fl* (flsin (fl* 0.09 x))
                                 (flcos (fl* 0.07 z))))
                   (fl* 2.2 (fl* (flsin (fl+ (fl* 0.21 x) 1.3))
                                 (flsin (fl* 0.18 z))))))
         1.4)))

(define terrain (mesh-heightmap 110.0 110.0 140 140 island))
(define water (mesh-plane 300.0 300.0))

(define terrain-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (varying vec3 v_n)
     (varying float v_h)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_n a_normal)
       (set! v_h a_pos.y)))
   '((precision mediump float)
     (uniform vec3 u_light)
     (uniform float u_clip)              ; 1 = discard below water
     (varying vec3 v_n)
     (varying float v_h)
     (define (main) void
       (if (< (* v_h u_clip) (- "0.05")) (discard))
       ;; sand at the shore, grass above, rock on the tops
       (local vec3 base (mix (vec3 "0.45" "0.38" "0.24")
                             (vec3 "0.13" "0.30" "0.11")
                             (smoothstep (fl 0 30) (fl 1 50) v_h)))
       (set! base (mix base (vec3 "0.32" "0.28" "0.25")
                       (smoothstep (fl 3 50) (fl 6) v_h)))
       (local float d (max (dot (normalize v_n) u_light) (fl 0)))
       (local vec3 c (* base (+ (fl 0 30) (* (fl 0 70) d))))
       (set! gl_FragColor
             (vec4 (pow c (vec3 "0.4545" "0.4545" "0.4545"))
                   (fl 1)))))))

(define water-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_rvp)                ; the reflection camera's VP
     (varying vec4 v_rclip)
     (varying vec3 v_wp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_rclip (* u_rvp (vec4 a_pos (fl 1))))
       (set! v_wp a_pos)))
   '((precision mediump float)
     (uniform sampler2D u_refl)
     (uniform vec3 u_eye)
     (uniform float u_time)
     (varying vec4 v_rclip)
     (varying vec3 v_wp)
     (define (main) void
       (local vec2 uv (+ (* (/ v_rclip.xy v_rclip.w) (fl 0 50))
                         (vec2 (fl 0 50) (fl 0 50))))
       ;; ripple the lookup with two moving waves
       (local float rx (* "0.008" (sin (+ (* v_wp.x "0.35")
                                          (* u_time "1.3")))))
       (local float ry (* "0.008" (sin (+ (* v_wp.z "0.30")
                                          (* u_time "1.7")))))
       (local vec4 refl (texture2D u_refl (+ uv (vec2 rx ry))))
       ;; Fresnel: flat views reflect, steep views see the deep
       (local vec3 v (normalize (- u_eye v_wp)))
       (local float f (pow (- (fl 1) (max v.y (fl 0))) "1.5"))
       (local vec3 deep (vec3 "0.05" "0.14" "0.18"))
       (local vec3 c (mix deep refl.rgb (+ (fl 0 20) (* (fl 0 75) f))))
       (set! gl_FragColor (vec4 c (fl 1)))))))

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

(define island-obj (upload terrain))
(define water-obj (upload water))
(define refl (fx-target! 400 300))

(define proj (m4-perspective 0.9 (/ 800.0 600.0) 0.5 500.0))
(define light (v3-normalize (v3 0.5 0.75 0.4)))

(define (draw-island! vp clip)
  (bind-upload! terrain-p island-obj)
  (fx-uniform! terrain-p 'u_mvp vp)
  (fx-uniform! terrain-p 'u_light (v3-x light) (v3-y light)
               (v3-z light))
  (fx-uniform! terrain-p 'u_clip clip)
  (cmd-draw-elements! GL-TRIANGLES (vector-ref island-obj 6)))

(fx-loop!
 (lambda (t dt)
   (cmd-depth! #t)
   (let* ((a (fl* 0.07 t))
          (eye (v3 (fl* 55.0 (flsin a)) 16.0 (fl* 55.0 (flcos a))))
          (center (v3 0.0 2.0 0.0))
          (vp (m4-mul proj (m4-look-at eye center (v3 0.0 1.0 0.0))))
          ;; the camera mirrored about y=0, aimed at the mirrored target
          (meye (v3 (v3-x eye) (fl- 0.0 (v3-y eye)) (v3-z eye)))
          (mcenter (v3 0.0 -2.0 0.0))
          (rvp (m4-mul proj (m4-look-at meye mcenter (v3 0.0 1.0 0.0)))))
     ;; pass 1: the world as the water sees it
     (fx-bind-target! refl)
     (cmd-clear! 0.63 0.71 0.81 1.0)
     (draw-island! rvp 1.0)
     ;; pass 2: the island, then the water over it
     (fx-bind-canvas!)
     (cmd-clear! 0.63 0.71 0.81 1.0)
     (draw-island! vp 0.0)
     (bind-upload! water-p water-obj)
     (cmd-bind-texture! 0 (fx-target-texture refl))
     (fx-uniform! water-p 'u_refl 0)
     (fx-uniform! water-p 'u_mvp vp)
     (fx-uniform! water-p 'u_rvp rvp)
     (fx-uniform! water-p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye))
     (fx-uniform! water-p 'u_time t)
     (cmd-draw-elements! GL-TRIANGLES (vector-ref water-obj 6)))))
