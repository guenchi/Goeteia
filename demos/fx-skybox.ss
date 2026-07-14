;; A skybox and a mirror ball.  The cube map is procedural: six faces
;; of deep-blue sky with a hazy horizon, a baked sun, and cumulus
;; from four octaves of 3D value noise -- noise over the view
;; DIRECTION, so the clouds cross the cube's face seams without a
;; visible edge.  All of it is RGBA bytes computed in a Scheme loop
;; and handed to gl-cubemap!.  The box draws first with the depth
;; test off (translation dies in the w=0 multiply, so the sky never
;; moves); the sphere samples the same cube map along the reflected
;; eye ray.  Needs WebGL 2.
(import (rnrs) (web sx) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh))

;; the demo mounts its own canvas where the hero usually lives
(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero"))
        (canvas (@ (id "c") (width "720") (height "400")
                   (style "display:block;width:100%;max-width:40em;border-radius:12px"))))))

(fx-init! (get-element-by-id "c"))

;; ---- the sky, baked: gradient + sun + clouds, six faces ----
(define DIM 128)
(define sun (v3-normalize (v3 0.55 0.45 0.35)))
(define sky-base (fx-alloc! (* 6 DIM DIM 4)))

(define (clamp01 v) (if (fl<? v 0.0) 0.0 (if (fl<? 1.0 v) 1.0 v)))
(define (byte! at v) (%mem-u8-set! at (%fl->fx (fl* (clamp01 v) 255.0))))
(define (mix a b k) (fl+ a (fl* (fl- b a) k)))
(define (sstep v) (fl* v (fl* v (fl- 3.0 (fl* 2.0 v)))))

;; ---- a tiny 3D value noise: hashed lattice corners, smooth
;; interpolation, four octaves.  Products stay under 2^30, so every
;; step is a plain fixnum
(define (h3 ix iy iz)                   ; lattice corner -> [0,1)
  (let* ((n (remainder (+ (+ (* ix 127) (* iy 311)) (* iz 74)) 21001))
         (n (if (< n 0) (+ n 21001) n))
         (m (remainder (* n (+ n 41)) 21001))
         (m (remainder (* m 167) 21001)))
    (fl/ (fixnum->flonum m) 21001.0)))

(define (vnoise x y z)
  (let* ((fx (flfloor x)) (fy (flfloor y)) (fz (flfloor z))
         (ix (%fl->fx fx)) (iy (%fl->fx fy)) (iz (%fl->fx fz))
         (ux (sstep (fl- x fx)))
         (uy (sstep (fl- y fy)))
         (uz (sstep (fl- z fz))))
    (mix (mix (mix (h3 ix iy iz) (h3 (+ ix 1) iy iz) ux)
              (mix (h3 ix (+ iy 1) iz) (h3 (+ ix 1) (+ iy 1) iz) ux)
              uy)
         (mix (mix (h3 ix iy (+ iz 1)) (h3 (+ ix 1) iy (+ iz 1)) ux)
              (mix (h3 ix (+ iy 1) (+ iz 1))
                   (h3 (+ ix 1) (+ iy 1) (+ iz 1)) ux)
              uy)
         uz)))

(define (fbm x y z)                     ; four octaves, 2x lacunarity
  (fl+ (fl* 0.5333 (vnoise x y z))
       (fl+ (fl* 0.2667 (vnoise (fl* x 2.0) (fl* y 2.0) (fl* z 2.0)))
            (fl+ (fl* 0.1333 (vnoise (fl* x 4.0) (fl* y 4.0)
                                     (fl* z 4.0)))
                 (fl* 0.0667 (vnoise (fl* x 8.0) (fl* y 8.0)
                                     (fl* z 8.0)))))))

;; face i, pixel (s,t) in [0,1] -> the direction it shows
(define (face-dir i a b)                ; a,b in [-1,1]
  (case i
    ((0) (v3 1.0 (fl- 0.0 b) (fl- 0.0 a)))
    ((1) (v3 -1.0 (fl- 0.0 b) a))
    ((2) (v3 a 1.0 b))
    ((3) (v3 a -1.0 (fl- 0.0 b)))
    ((4) (v3 a (fl- 0.0 b) 1.0))
    (else (v3 (fl- 0.0 a) (fl- 0.0 b) -1.0))))

(define FDIM (fixnum->flonum DIM))
(let face ((i 0))
  (when (< i 6)
    (let pixel ((p 0))
      (when (< p (* DIM DIM))
        (let* ((s (fl/ (fl+ (fixnum->flonum (remainder p DIM)) 0.5) FDIM))
               (t (fl/ (fl+ (fixnum->flonum (quotient p DIM)) 0.5) FDIM))
               (d (v3-normalize
                   (face-dir i (fl- (fl* 2.0 s) 1.0)
                             (fl- (fl* 2.0 t) 1.0))))
               (y (v3-y d))
               (glow (clamp01 (fl/ (fl- (v3-dot d sun) 0.95) 0.05)))
               (k (fl* glow glow))
               (at (+ sky-base (* (+ (* i (* DIM DIM)) p) 4))))
          (if (fl<? y 0.0)              ; below the horizon: open sea,
              (begin                    ; bright at the line, deep down
                (byte! at (mix 0.36 0.04 (fl- 0.0 y)))
                (byte! (+ at 1) (mix 0.47 0.12 (fl- 0.0 y)))
                (byte! (+ at 2) (mix 0.58 0.20 (fl- 0.0 y))))
              ;; the sky: a deep zenith washed white toward the
              ;; horizon, cumulus where the fbm rises past its
              ;; threshold (fading in just above the horizon, lit
              ;; toward the sun), and the sun's glow over everything
              (let* ((haze (fl* (fl- 1.0 y)
                                (fl* (fl- 1.0 y) (fl- 1.0 y))))
                     (r0 (mix 0.13 0.80 haze))
                     (g0 (mix 0.30 0.87 haze))
                     (b0 (mix 0.65 0.95 haze))
                     (cd (fbm (fl+ (fl* (v3-x d) 2.8) 37.7)
                              (fl+ (fl* (v3-y d) 2.8) 7.7)
                              (fl+ (fl* (v3-z d) 2.8) 19.3)))
                     (cov (fl* (sstep (clamp01 (fl/ (fl- cd 0.47) 0.20)))
                               (sstep (clamp01 (fl+ 0.12 (fl* y 5.0))))))
                     ;; thin cirrus, higher frequency, well above
                     (ci (fl* (fl* 0.5 (clamp01
                                        (fl/ (fl- (fbm (fl+ (fl* (v3-x d) 6.0) 13.1)
                                                       (fl+ (fl* (v3-y d) 6.0) 51.9)
                                                       (fl+ (fl* (v3-z d) 6.0) 27.4))
                                                  0.60)
                                             0.24)))
                              (sstep (clamp01 (fl- (fl* y 4.0) 0.6)))))
                     (cover (clamp01 (fl+ cov ci)))
                     ;; sunlit tops, shaded bellies
                     (lit (fl+ (mix 0.80 0.98 (clamp01 (v3-dot d sun)))
                               (fl* -0.10 (fl- 1.0 (clamp01 (fl* y 3.0))))))
                     (cw (fl* lit (fl+ 0.9 (fl* 0.1 cd)))))
                (byte! at (fl+ (mix r0 cw cover) k))
                (byte! (+ at 1) (fl+ (mix g0 cw cover) (fl* k 0.9)))
                (byte! (+ at 2) (fl+ (mix b0 (fl* cw 0.99) cover)
                                     (fl* k 0.6)))))
          (%mem-u8-set! (+ at 3) 255))
        (pixel (+ p 1))))
    (face (+ i 1))))

(define sky-map (fx-slot!))
(gl-cubemap! sky-map sky-base DIM)

;; ---- the skybox program: a cube that never moves ----
(define sky-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_vp)
     (varying vec3 v_dir)
     (define (main) void
       (set! v_dir a_pos)
       (local vec4 p (* u_vp (vec4 a_pos (fl 0))))
       (set! gl_Position p.xyww)))
   '((precision mediump float)
     (uniform samplerCube u_sky)
     (varying vec3 v_dir)
     (define (main) void
       (set! gl_FragColor (textureCube u_sky v_dir))))))

;; ---- the mirror ball: reflect the eye ray into the sky ----
(define env-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_model)
     (varying vec3 v_n)
     (varying vec3 v_wp)
     (define (main) void
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_wp (vec3 (* u_model (vec4 a_pos (fl 1)))))
       (set! v_n (vec3 (* u_model (vec4 a_normal (fl 0)))))))
   '((precision mediump float)
     (uniform samplerCube u_sky)
     (uniform vec3 u_eye)
     (uniform float u_time)
     (varying vec3 v_n)
     (varying vec3 v_wp)
     (define (main) void
       (local vec3 n (normalize v_n))
       (local vec3 e (normalize (- u_eye v_wp)))
       (local vec3 r (reflect (- e) n))
       ;; rays into the water see the sea band of the cube map --
       ;; wobble them with the swell so the ball's waterline lives
       (if (< r.y (fl 0))
           (set! r.y (+ r.y (* "0.10"
                               (sin (+ (* (+ v_wp.x v_wp.z) "3.0")
                                       (* u_time "1.6")))))))
       (local vec4 sky (textureCube u_sky r))
       ;; a hint of fresnel: grazing angles reflect harder
       (local float f (- (fl 1) (max (dot n e) (fl 0))))
       (set! gl_FragColor
             (vec4 (* sky.rgb (+ (fl 0 70) (* (fl 0 45) f)))
                   (fl 1)))))))

;; ---- the sea: a planar reflection, rippled ----
;; Pass 1 renders the world as the water sees it (the camera
;; mirrored about the surface) into a texture; each sea fragment
;; projects itself through that mirrored camera, offsets the lookup
;; by its wave normal, and Fresnel-blends the reflection over the
;; deep -- so the BALL stands in the water, upside down, riding the
;; same swell as the clouds.  The sun's glitter path goes on top.
(define sea-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_rvp)                ; the reflection camera's VP
     (uniform mat4 u_model)
     (varying vec4 v_rclip)
     (varying vec3 v_wp)
     (define (main) void
       (local vec4 w (* u_model (vec4 a_pos (fl 1))))
       (set! gl_Position (* u_mvp (vec4 a_pos (fl 1))))
       (set! v_rclip (* u_rvp (vec4 a_pos (fl 1))))
       (set! v_wp w.xyz)))
   '((precision mediump float)
     (uniform sampler2D u_refl)
     (uniform vec3 u_eye)
     (uniform vec3 u_sun)
     (uniform float u_time)
     (varying vec4 v_rclip)
     (varying vec3 v_wp)
     (define (main) void
       (local float nx (+ (* "0.045" (sin (+ (* v_wp.x "1.7")
                                             (* u_time "1.1"))))
                          (* "0.028" (sin (+ (* (+ v_wp.x v_wp.z) "3.1")
                                             (* u_time "1.9"))))))
       (local float nz (+ (* "0.045" (sin (+ (* v_wp.z "1.4")
                                             (* u_time "1.4"))))
                          (* "0.028" (sin (+ (* (- v_wp.z v_wp.x) "2.6")
                                             (* u_time "1.6"))))))
       (local vec3 n (normalize (vec3 nx (fl 1) nz)))
       ;; where the mirrored camera saw this spot, wave-shifted
       (local vec2 uv (+ (* (/ v_rclip.xy v_rclip.w) (fl 0 50))
                         (vec2 (fl 0 50) (fl 0 50))))
       (local vec4 refl (texture2D u_refl (+ uv (* (vec2 nx nz) "0.35"))))
       ;; flat views mirror the world, steep ones see into the deep
       (local vec3 v (normalize (- u_eye v_wp)))
       (local float f (+ (fl 0 25)
                         (* (fl 0 75)
                            (pow (- (fl 1) (max (dot n v) (fl 0)))
                                 (fl 3)))))
       (local vec3 c (mix (vec3 "0.05" "0.16" "0.24") refl.rgb f))
       (local vec3 r (reflect (- v) n))
       (local float sp (pow (max (dot r u_sun) (fl 0)) "180.0"))
       (set! c (+ c (* (vec3 (fl 1) (fl 0 90) (fl 0 70)) sp)))
       (set! gl_FragColor (vec4 c (fl 1)))))))

;; ---- geometry ----

(define cube (fx-mesh! (mesh-box 2.0 2.0 2.0)))
(define ball (fx-mesh! (mesh-sphere 1.4 48 24)))
(define sea (fx-mesh! (mesh-plane 240.0 240.0)))
(define refl (fx-target! 400 300))      ; the world, as the sea sees it

(define proj (m4-perspective 0.9 (/ 720.0 400.0) 0.1 100.0))
(define SEA-Y -0.4)
(define ball-m (m4-translate 0.0 1.0 0.0))
(define sea-m (m4-translate 0.0 SEA-Y 0.0))

;; the sky and the ball, from any camera -- pass 1 draws them into
;; the reflection target, pass 2 onto the canvas
(define (draw-world! vp cam t)
  (cmd-depth! #f)
  (fx-mesh-use! sky-p cube)
  (cmd-bind-cubemap! 0 sky-map)
  (fx-uniform! sky-p 'u_sky 0)
  (fx-uniform! sky-p 'u_vp vp)
  (fx-mesh-draw! cube)
  (cmd-depth! #t)
  (fx-mesh-use! env-p ball)
  (cmd-bind-cubemap! 0 sky-map)
  (fx-uniform! env-p 'u_sky 0)
  (fx-uniform! env-p 'u_mvp (m4-mul vp ball-m))
  (fx-uniform! env-p 'u_model ball-m)
  (fx-uniform! env-p 'u_eye (v3-x cam) (v3-y cam) (v3-z cam))
  (fx-uniform! env-p 'u_time t)
  (fx-mesh-draw! ball))

(fx-loop!
 (lambda (t dt)
   (let* ((a (fl* 0.15 t))
          (eye (v3 (fl* 9.0 (flsin a)) 2.5 (fl* 9.0 (flcos a))))
          (vp (m4-mul proj (m4-look-at eye (v3 0.0 1.0 0.0)
                                       (v3 0.0 1.0 0.0))))
          ;; the camera mirrored about the sea surface
          (meye (v3 (v3-x eye) (fl- (fl* 2.0 SEA-Y) (v3-y eye))
                    (v3-z eye)))
          (rvp (m4-mul proj
                       (m4-look-at meye
                                   (v3 0.0 (fl- (fl* 2.0 SEA-Y) 1.0) 0.0)
                                   (v3 0.0 1.0 0.0)))))
     ;; pass 1: sky and ball as the water sees them
     (cmd-unbind-texture! 0)            ; the sea sampled it last frame
     (fx-bind-target! refl)
     (cmd-clear! 0.0 0.0 0.0 1.0)
     (draw-world! rvp meye t)
     ;; pass 2: the same world, then the sea reflecting it
     (fx-bind-canvas!)
     (cmd-clear! 0.0 0.0 0.0 1.0)
     (draw-world! vp eye t)
     (fx-mesh-use! sea-p sea)
     (cmd-bind-texture! 0 (fx-target-texture refl))
     (fx-uniform! sea-p 'u_refl 0)
     (fx-uniform! sea-p 'u_mvp (m4-mul vp sea-m))
     (fx-uniform! sea-p 'u_rvp (m4-mul rvp sea-m))
     (fx-uniform! sea-p 'u_model sea-m)
     (fx-uniform! sea-p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye))
     (fx-uniform! sea-p 'u_sun (v3-x sun) (v3-y sun) (v3-z sun))
     (fx-uniform! sea-p 'u_time t)
     (fx-mesh-draw! sea))))
