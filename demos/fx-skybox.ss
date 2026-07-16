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
              (let* ((sea (sstep (clamp01 (fl* (fl- 0.0 y) 1.25)))))
                ;; Match the sky haze at y=0, then fall off to deep sea.
                (byte! at (mix 0.74 0.04 sea))
                (byte! (+ at 1) (mix 0.83 0.12 sea))
                (byte! (+ at 2) (mix 0.92 0.20 sea)))
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
       (local vec4 sky (textureCube u_sky v_dir))
       (set! gl_FragColor (vec4 sky.rgb (fl 1)))))))

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
       ;; downward rays see the WATER, and near-grazing water is a
       ;; mirror: the sky continues a whole band below the geometric
       ;; horizon, so the VISIBLE waterline -- where the mirror gives
       ;; way to looking into the sea -- sits well below the ball's
       ;; midline (the eye rides above the ball's centre, which alone
       ;; would put the horizon slightly high).  The line is a tight
       ;; step, and the sea it opens into samples deep under the
       ;; horizon so it stays dark against the bright horizon bake.
       ;; The swell wobbles the line.
       (local float wob (* (fl 0 10) (sin (+ (* (+ v_wp.x v_wp.z) (fl 3))
                                             (* u_time (fl 1 60))))))
       (local float yw (+ r.y (* wob (smoothstep (fl 0) (fl 0 10)
                                                 (- r.y)))))
       (local vec4 up (textureCube u_sky (vec3 r.x (abs yw) r.z)))
       (local vec4 dn (textureCube u_sky (vec3 r.x (- yw (fl 0 35)) r.z)))
       (local float t (smoothstep (fl 0) (fl 0 20)
                                  (- (fl 0) (+ yw (fl 0 35)))))
       ;; below the line the water is STILL a mirror: keep the
       ;; mirrored sky's detail, dimmed and shifted toward the water,
       ;; with the deep band rising through it -- not a flat gradient
       (local vec3 wat (+ (* up.rgb (vec3 (fl 0 27) (fl 0 38) (fl 0 45)))
                          (* dn.rgb (fl 0 32))))
       (local vec3 c (mix up.rgb wat t))
       ;; a hint of fresnel: grazing angles reflect harder
       (local float f (- (fl 1) (max (dot n e) (fl 0))))
       (set! gl_FragColor
             (vec4 (* c (+ (fl 0 70) (* (fl 0 45) f)))
                   (fl 1)))))))

;; ---- the sea: a restrained displaced dielectric surface ----
;; Pass 1 renders only the ball as the water sees it (the camera
;; mirrored about the mean surface); sky radiance comes directly from
;; the cubemap.  Broad waves move geometry in the foreground; finer
;; waves alter the normal over the whole sea.  The ball is partially
;; immersed inside one localized contact ripple.
(define sea-p
  (fx-program!
   '((attribute vec3 a_pos)
     (attribute vec3 a_normal)
     (uniform mat4 u_mvp)
     (uniform mat4 u_rvp)                ; the reflection camera's VP
     (uniform mat4 u_model)
     (uniform vec3 u_eye)
     (uniform float u_time)
     (varying vec4 v_rclip)
     (varying vec3 v_wp)
     (varying vec2 v_gslope)
     (varying float v_wave)
     (varying float v_dist)
     (varying float v_warp)
     (define (main) void
       (local vec4 w0 (* u_model (vec4 a_pos (fl 1))))
       (local float eye_dist (distance u_eye w0.xyz))
       (local float near (- (fl 1)
                            (smoothstep "18.0" "48.0" eye_dist)))
       (local float contact (smoothstep "0.80" "2.80" (length w0.xz)))
       (local float amp (* near contact))
       (local float p0 (+ (+ (* w0.x "0.13") (* w0.z "0.05"))
                          (* u_time "0.38")))
       (local float p1 (+ (+ (* w0.x "-0.07") (* w0.z "0.15"))
                          (* u_time "0.31")))
       (local float p2 (+ (+ (* w0.x "0.21") (* w0.z "-0.12"))
                          (* u_time "0.61")))
       (local float h (* amp (+ (+ (* "0.070" (sin p0))
                                     (* "0.045" (sin p1)))
                                  (* "0.025" (sin p2)))))
       (local float gx (* amp (+ (+ (* "0.0091" (cos p0))
                                      (* "-0.00315" (cos p1)))
                                   (* "0.00525" (cos p2)))))
       (local float gz (* amp (+ (+ (* "0.0035" (cos p0))
                                      (* "0.00675" (cos p1)))
                                   (* "-0.0030" (cos p2)))))
       (local vec4 p (vec4 a_pos.x h a_pos.z (fl 1)))
       (local vec4 w (* u_model p))
       (set! gl_Position (* u_mvp p))
       (set! v_rclip (* u_rvp p))
       (set! v_wp w.xyz)
       (set! v_gslope (vec2 gx gz))
       (set! v_wave h)
       (set! v_dist eye_dist)
       (set! v_warp
             (sin (+ (+ (* w0.x "0.11") (* w0.z "-0.17"))
                     (* u_time "0.20"))))))
   '((precision highp float)
     (uniform sampler2D u_refl)
     (uniform samplerCube u_sky)
     (uniform vec3 u_eye)
     (uniform vec3 u_sun)
     (uniform float u_time)
     (varying vec4 v_rclip)
     (varying vec3 v_wp)
     (varying vec2 v_gslope)
     (varying float v_wave)
     (varying float v_dist)
     (varying float v_warp)
     (define (main) void
       ;; Phase-warped directions avoid the evenly spaced ridges that
       ;; ordinary stacked sine waves produce in perspective.
       (local float far (smoothstep "20.0" "82.0" v_dist))
       ;; The detail spectrum still exists everywhere, but its
       ;; sub-pixel octaves are filtered out before the horizon.
       (local float dnear (- (fl 1)
                             (smoothstep "12.0" "52.0" v_dist)))
       ;; scaled down so the mirrored sky stays coherent, not scrambled
       (local float detail (* "0.55" (* dnear dnear)))
       ;; The slow phase warp is evaluated per vertex and interpolated.
       (local float q0 (+ (+ (+ (* v_wp.x "0.74") (* v_wp.z "0.43"))
                             (* u_time "1.37"))
                          (* "0.55" v_warp)))
       (local float q1 (+ (+ (+ (* v_wp.x "-0.46") (* v_wp.z "1.07"))
                             (* u_time "-1.70"))
                          (* "-0.42" v_warp)))
       (local float q2 (+ (+ (+ (* v_wp.x "1.63") (* v_wp.z "-0.72"))
                             (* u_time "2.10"))
                          (* "0.32" v_warp)))
       (local float q3 (+ (+ (+ (* v_wp.x "-2.10") (* v_wp.z "-1.34"))
                             (* u_time "2.80"))
                          (* "-0.25" v_warp)))
       (local float c0 (cos q0))
       (local float c1 (cos q1))
       (local float c2 (cos q2))
       (local float c3 (cos q3))
       (local float s1 (sin q1))
       (local float hx (+ v_gslope.x
                           (* detail
                              (+ (+ (* "0.020" c0)
                                    (* "-0.014" c1))
                                 (+ (* "0.009" c2)
                                    (* "-0.005" c3))))))
       (local float hz (+ v_gslope.y
                           (* detail
                              (+ (+ (* "0.012" c0)
                                    (* "0.021" c1))
                                 (+ (* "-0.010" c2)
                                    (* "-0.006" c3))))))
       ;; A small, phase-warped contact ripple makes the partially
       ;; immersed ball read as touching without reaching the horizon.
       (local float radial2 (dot v_wp.xz v_wp.xz))
       (local float ring (fl 0))
       (local float crp (fl 1))
       (if (< radial2 "25.0")
         (local float radial (sqrt radial2))
         (set! ring (* (smoothstep "0.45" "0.80" radial)
                       (- (fl 1) (smoothstep "1.30" "4.80" radial))))
         (local float rp (+ (+ (* radial "4.60") (* u_time "-1.40"))
                            (* "0.35" (sin (+ (* v_wp.x "0.31")
                                               (* v_wp.z "-0.27"))))))
         (set! crp (cos rp))
         (local float rg (* "0.042" (* ring crp)))
         (local vec2 rd (/ v_wp.xz (max radial "0.001")))
         (set! hx (+ hx (* rg rd.x)))
         (set! hz (+ hz (* rg rd.y))))
       (local vec3 n (normalize (vec3 (- hx) (fl 1) (- hz))))
       ;; Project the displaced point through the same reflection
       ;; camera, then apply only a small normal-driven lookup shift.
       (local vec2 uv (+ (* (/ v_rclip.xy v_rclip.w) (fl 0 50))
                         (vec2 (fl 0 50) (fl 0 50))))
       (local vec3 v (normalize (- u_eye v_wp)))
       (local float ndv (max (dot n v) (fl 0)))
       (local vec3 r (reflect (- v) n))
       (local float rnear (- (fl 1)
                             (smoothstep "24.0" "82.0" v_dist)))
       (local float damp (* rnear (mix "0.30" (fl 1) ndv)))
       (local vec2 ruv (+ uv (* n.xz (* "0.038" damp))))
       (set! ruv (clamp ruv (vec2 "0.002" "0.002")
                        (vec2 "0.998" "0.998")))
       ;; glassiness grows with distance: near water is looked INTO,
       ;; far water is a mirror
       (local float glass (smoothstep "8.0" "60.0" v_dist))
       ;; far water's flat mirror would only see the featureless haze
       ;; band; lift its sample toward the clouded sky so the glass
       ;; has something to mirror
       (local vec3 rsky (vec3 r.x (+ r.y (* "0.12" far)) r.z))
       (local vec4 envrefl (textureCube u_sky rsky))
       (local vec3 reflected envrefl.rgb)
       ;; The ball occupies a stable, central ellipse in reflection UV.
       ;; Skip both 2D texture reads for the rest of the water surface.
       (local vec2 ball_uv
              (/ (- ruv (vec2 "0.50" "0.78"))
                 (vec2 "0.22" "0.28")))
       (if (< (dot ball_uv ball_uv) (fl 1))
         (local vec2 roff (* (vec2 c0 s1) (* "0.003" dnear)))
         (local vec4 rough1 (texture2D u_refl (+ ruv roff)))
         (local vec4 rough2 (texture2D u_refl (- ruv roff)))
         (local vec3 roughrefl (* (+ rough1.rgb rough2.rgb) "0.5"))
         (local float objectmask
                (smoothstep "0.08" "0.88"
                            (* (+ rough1.a rough2.a) "0.5")))
         (set! reflected (mix reflected roughrefl objectmask)))
       ;; Exact x^120 using multiplies avoids a general pow instruction.
       (local float sun_dot (max (dot r u_sun) (fl 0)))
       (local float sp2 (* sun_dot sun_dot))
       (local float sp4 (* sp2 sp2))
       (local float sp8 (* sp4 sp4))
       (local float sp16 (* sp8 sp8))
       (local float sp32 (* sp16 sp16))
       (local float sp64 (* sp32 sp32))
       (local float sp (* (* sp64 sp32) (* sp16 sp8)))
       (set! reflected
             (+ reflected (* (vec3 "0.90" "0.76" "0.52")
                             (* sp "0.65"))))
       ;; Schlick Fresnel with a distance-graded floor: near water
       ;; keeps the physical air-to-water base (0.02, transparent --
       ;; the eye looks INTO it), far water lifts to 0.14 so the
       ;; mirror reads; the grazing law stands throughout
       (local float f0 (mix "0.02" "0.22" glass))
       (local float one_minus_ndv (- (fl 1) ndv))
       (local float one_minus_ndv2 (* one_minus_ndv one_minus_ndv))
       (local float f (+ f0
                         (* (- (fl 1) f0)
                            (* (* one_minus_ndv2 one_minus_ndv2)
                               one_minus_ndv))))
       (local float crest (clamp (+ "0.50" (* v_wave "3.20"))
                                 (fl 0) (fl 1)))
       (local float grain (clamp (+ (+ (+ "0.50"
                                           (* "0.28" c0))
                                        (* "0.16" c1))
                                     (* "0.08" c2))
                                 (fl 0) (fl 1)))
       (local float micro (mix (fl 1) (mix "0.90" "1.10" grain)
                               dnear))
       (local float ringtone (+ (fl 1) (* "0.10" (* ring crp))))
       (local vec3 transmitted
              (* (mix (vec3 "0.17" "0.29" "0.37")
                      (vec3 "0.21" "0.34" "0.42") far)
                 (* (* (mix "0.95" "1.05" crest) micro) ringtone)))
       ;; The two lobes share one unit of energy.
       (local vec3 c (+ (* reflected f)
                        (* transmitted (- (fl 1) f))))
       (set! gl_FragColor (vec4 c (fl 1)))))))

;; ---- geometry ----

(define cube (fx-mesh! (mesh-box 2.0 2.0 2.0)))
(define ball (fx-mesh! (mesh-sphere 1.4 40 20)))
(define sea (fx-mesh! (mesh-heightmap 700.0 700.0 128 128
                                       (lambda (x z) 0.0))))
(define refl (fx-target! 576 320))      ; ball-only target at the canvas aspect

(define proj (m4-perspective 0.9 (/ 720.0 400.0) 0.1 260.0))
(define SEA-Y -0.4)
(define ball-m (m4-translate 0.0 0.75 0.0)) ; visibly partially immersed
(define sea-m (m4-translate 0.0 SEA-Y 0.0))
(define reflection-frame 0)
(define reflection-vp proj)

;; Draw the visible world; the reflection pass omits the sky because
;; the sea samples that radiance directly from the cubemap.
(define (draw-world! vp cam reflection-pass t)
  ;; The reflection texture only needs the ball's alpha-masked radiance;
  ;; the sea samples its sky reflection directly from the cubemap.
  (when (fl=? reflection-pass 0.0)
    (cmd-depth! #f)
    (fx-mesh-use! sky-p cube)
    (cmd-bind-cubemap! 0 sky-map)
    (fx-uniform! sky-p 'u_sky 0)
    (fx-uniform! sky-p 'u_vp vp)
    (fx-mesh-draw! cube))
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
           (eye (v3 (fl* 9.0 (flsin a)) 2.2 (fl* 9.0 (flcos a))))
           (vp (m4-mul proj (m4-look-at eye (v3 0.0 1.0 0.0)
                                        (v3 0.0 1.0 0.0)))))
     ;; The mirrored camera moves slowly, so cache the ball reflection
     ;; and its matching projection for one frame.  The first frame
     ;; always renders the target.
     (when (= reflection-frame 0)
       (let* ((meye (v3 (v3-x eye)
                         (fl- (fl* 2.0 SEA-Y) (v3-y eye))
                         (v3-z eye)))
              (rvp (m4-mul
                    proj
                    (m4-look-at
                     meye
                     (v3 0.0 (fl- (fl* 2.0 SEA-Y) 1.0) 0.0)
                     (v3 0.0 1.0 0.0)))))
         (set! reflection-vp rvp)
         (cmd-unbind-texture! 0)        ; the sea sampled it last frame
         (fx-bind-target! refl)
         (cmd-clear! 0.0 0.0 0.0 0.0)
         (draw-world! reflection-vp meye 1.0 t)))
     (set! reflection-frame (remainder (+ reflection-frame 1) 2))
     ;; pass 2: the same world, then the sea reflecting it
     (fx-bind-canvas!)
     (cmd-clear! 0.0 0.0 0.0 1.0)
     (draw-world! vp eye 0.0 t)
     (fx-mesh-use! sea-p sea)
     (cmd-bind-texture! 0 (fx-target-texture refl))
     (cmd-bind-cubemap! 1 sky-map)
     (fx-uniform! sea-p 'u_refl 0)
     (fx-uniform! sea-p 'u_sky 1)
     (fx-uniform! sea-p 'u_mvp (m4-mul vp sea-m))
     (fx-uniform! sea-p 'u_rvp (m4-mul reflection-vp sea-m))
     (fx-uniform! sea-p 'u_model sea-m)
     (fx-uniform! sea-p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye))
     (fx-uniform! sea-p 'u_sun (v3-x sun) (v3-y sun) (v3-z sun))
     (fx-uniform! sea-p 'u_time t)
     (fx-mesh-draw! sea))))
