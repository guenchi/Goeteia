;; Thanks to @eazhou99, who spent six hours painting this black hole.
;;
;; The live editor compiles every Run at -O0 for keystroke speed; this
;; directive overrides it (last one wins) so the million-particle fill
;; and the frame arithmetic get the full optimization passes -- phones
;; feel the difference.
(%opt 2)
;;
;; A black hole's accretion disk, a million particles whose
;; physics is arithmetic in the vertex shader: each particle is four
;; numbers (radius, phase, height, seed) and its position is a pure
;; function of time -- Keplerian shear, the inner disk lapping the
;; outer.  The lensing is a conformal trick: in screen space every
;; point slides out along r' = r + k/r, which has a minimum at 2*sqrt(k)
;; -- so no image lands inside the photon ring and light crowds the
;; ring; the silhouette itself is restored by an explicit stamp and
;; the ring painted at the caustic radius (additive density alone
;; cannot hold an exact edge).  The
;; strong bending is a fold: the flat disk's far side is rotated up
;; over the hole by an angle that grows with depth, so its image is
;; the wide arch the renderers show -- height following disk radius,
;; joined to the flat band at the sides -- while the near band
;; crosses in front of the shadow.  The Doppler treatment is
;; relativistic: Keplerian beta ~ 0.55c at the inner edge, delta =
;; 1/(gamma(1 - beta cos theta)), intensity delta^4 (I/nu^3 is
;; invariant) -- the approaching side blazes, the receding side all
;; but goes out -- and T_obs = delta T_emit walks a blackbody ramp
;; from deep red through white to blue-white.  Needs WebGL 2.
(import (rnrs) (web sx) (web js) (web dom) (gfx gl) (gfx glsl) (gfx fx)
        (gfx mat) (gfx mesh) (gfx post))

;; the demo mounts its own canvas where the hero usually lives
(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero"))
        (canvas (@ (id "c") (width "720") (height "400")
                   (style "display:block;width:100%;max-width:40em;border-radius:12px"))))))

(fx-init! (get-element-by-id "c"))

(define N 1500000)

;; A sparse, cold star field sits behind the hot disk.  The centre is
;; explicitly masked by the photon shadow; without that mask a backdrop
;; would shine through what used to be black merely because no disk
;; particle landed there.
(define backdrop-q
  (fx-fullscreen!
   '((precision highp float)
     (uniform float u_time)
     (uniform vec2 u_resolution)
     (define (hash21 (vec2 p)) float
       (return (fract (* (sin (dot p (vec2 "127.1" "311.7")))
                          "43758.5453"))))
     (define (main) void
       (local vec2 uv (/ gl_FragCoord.xy u_resolution))
       (local vec2 p (- (* uv "2.0") (vec2 (fl 1) (fl 1))))
       (local vec2 drift
              (vec2 (* u_time "0.00022")
                    (* (sin (* u_time "0.075")) "0.0008")))
       (local vec2 sg (* (+ uv drift) (vec2 "330.0" "185.0")))
       (local vec2 cell (floor sg))
       (local vec2 fp (- (fract sg) (vec2 (fl 0 50) (fl 0 50))))
       (local float h (hash21 cell))
       (local float star
              (* (- (fl 1) (smoothstep "0.008" "0.105" (dot fp fp)))
                 (smoothstep "0.993" "0.9994" h)))
       (local float veil
              (* (exp (- (* (+ (* (+ p.y "0.18") (+ p.y "0.18"))
                                  (* (+ p.x "0.35") (+ p.x "0.35") "0.18"))
                               "2.6")))
                 (+ "0.65" (* h "0.35"))))
       (local vec3 sky
              (+ (vec3 "0.0015" "0.004" "0.013")
                 (* (vec3 "0.018" "0.040" "0.095") (* veil "0.55"))
                 (* (mix (vec3 "0.62" "0.75" (fl 1))
                         (vec3 (fl 1) "0.82" "0.58") h)
                    (* star (+ "0.35" (* h "1.7"))))))
       (local float shadow_r (length (vec2 (* p.x "1.8") p.y)))
       (local float shadow (smoothstep "0.365" "0.394" shadow_r))
       ;; The conformal particle map has its caustic at
       ;; 2*sqrt(0.03645) = 0.382.  Draw that same radius as a narrow
       ;; photon-ring border, behind the foreground disk.  Its colour
       ;; leans warm on the receding side and cool on the approaching
       ;; side, echoing the Doppler split carried by the particles.
       (local float photon
              (exp (- (* (abs (- shadow_r "0.382")) "350.0"))))
       (local vec3 photon_col
              (mix (vec3 (fl 1) "0.78" "0.55")
                   (vec3 "0.80" "0.90" (fl 1))
                   (smoothstep "-0.55" "0.55" p.x)))
       (set! sky (+ (* sky shadow) (* photon_col (* photon "0.68"))))
       (set! gl_FragColor (vec4 sky (fl 1)))))))

;; A restrained veiling glare ties the hot disk to the surrounding
;; vacuum.  It is broad enough to reach the frame edges, but the exact
;; shadow pass below restores the event horizon to pure black.
(define glow-veil-q
  (fx-fullscreen!
   '((precision highp float)
     (uniform vec2 u_resolution)
     (define (main) void
       (local vec2 p
              (- (* (/ gl_FragCoord.xy u_resolution) "2.0")
                 (vec2 (fl 1) (fl 1))))
       (local vec2 q (vec2 (* p.x "1.08") (* p.y "1.55")))
       (local float radial (exp (- (* (dot q q) "1.45"))))
       (local float horizontal
              (exp (- (+ (* (abs p.y) "2.45")
                         (* (abs p.x) "0.72")))))
       (local float veil
              (+ "0.0035" (+ (* radial "0.026")
                               (* horizontal "0.011"))))
       (local vec3 warm (vec3 (fl 1) "0.86" "0.74"))
       (local vec3 cool (vec3 "0.78" "0.88" (fl 1)))
       (local vec3 tint
              (mix warm cool (smoothstep "-0.65" "0.65" p.x)))
       (set! gl_FragColor (vec4 (* tint veil) veil))))))

;; Lensed particles are additive, so density alone cannot guarantee a
;; geometrically exact event-horizon silhouette.  This pass is drawn
;; after both lensed images and before the foreground disk: it stamps a
;; true aspect-correct circle into the HDR scene, then the direct disk is
;; allowed to occlude that circle exactly as in the setting diagram.
(define shadow-q
  (fx-fullscreen!
   '((precision highp float)
     (uniform vec2 u_resolution)
     (define (main) void
       (local vec2 p
              (- (* (/ gl_FragCoord.xy u_resolution) "2.0")
                 (vec2 (fl 1) (fl 1))))
       (local float r (length (vec2 (* p.x "1.8") p.y)))
       (local float mask
              (- (fl 1) (smoothstep "0.365" "0.375" r)))
       (set! gl_FragColor (vec4 (fl 0) (fl 0) (fl 0) mask))))))

(define disk-p
  (fx-program!
   '((attribute float a_r)
     (attribute float a_ph)
     (attribute float a_h)
     (attribute float a_seed)
     (uniform mat4 u_view)
     (uniform mat4 u_proj)
     (uniform vec3 u_eye)
     (uniform float u_t)
     (uniform float u_fold)              ; the pass's full fold angle
     (uniform float u_scale)             ; its demagnification
     (uniform float u_wide)              ; horizontal width of this image
     (uniform float u_drop)              ; its centring drop
     (uniform float u_gate)              ; 1: far side only
     (uniform float u_lens)              ; 0: direct disk, 1: lensed image
     (uniform float u_thick)             ; projected material thickness
     (uniform float u_sparse)            ; 1: sparse, 2: rare, 3: far wisps
     (uniform float u_gain)              ; its brightness
     (varying float v_dopp)
     (varying float v_temp)
     (varying float v_seed)
     (varying float v_fade)
     (varying float v_lens)
     (varying float v_occ)
     (define (main) void
       ;; Kepler: the angular rate falls as r^-3/2
       (local float ang (+ a_ph (/ (* u_t "2.6") (* a_r (sqrt a_r)))))
       (local float flow_h
              (* a_r
                 (+ (* "0.032"
                       (sin (+ (+ (* a_r "4.2") (* ang "-5.0"))
                               (* u_t "0.42"))))
                    (* "0.014"
                       (sin (+ (+ (* a_r "9.7") (* ang "3.0"))
                               (* u_t "-0.23")))))))
       (local vec3 wp (vec3 (* a_r (cos ang))
                            (+ a_h flow_h)
                            (* a_r (sin ang))))
       (local vec4 pv (* u_view (vec4 wp (fl 1))))
       (local vec4 bh (* u_view (vec4 (fl 0) (fl 0) (fl 0) (fl 1))))
       ;; the strong-bend fold: the flat disk's far side is seen OVER
       ;; the hole, as if folded up toward the camera -- rotate each
       ;; behind-the-hole point about the horizontal axis by an angle
       ;; that grows with its depth, so the arch's height follows the
       ;; disk radius and spans the disk's whole width (at the sides
       ;; the depth is zero and the fold hands back the flat band)
       (local float D (- bh.z pv.z))
       ;; ONE transition drives everything: the knee, the fold's
       ;; progress by azimuth (D over the ring's own radius).  Fold
       ;; angle, the centring drop, the conformal gate and the
       ;; secondary's fade all ride it together -- at knee 1 each
       ;; point is exactly the approved full transform, at knee 0 the
       ;; flat band, and in between the four stay consistent, so the
       ;; arc ends bend tangent into the band and nothing ever lands
       ;; inside the shadow (a fast fold over a slow drop did)
       ;; a QUINTIC ramp (zero second derivative at both ends): where
       ;; the transition meets the saturated circle the curvature is
       ;; continuous too, so the arcs carry no crease -- smoothstep is
       ;; only C1 and its curvature jump drew a visible fold line.
       ;; A long shoulder is essential to the movie geometry: bending
       ;; begins well out on the horizontal disk and remains visibly
       ;; oblique before it reaches the saturated upper arch.
       (local float kt (clamp (/ (/ D a_r) "1.30") (fl 0) (fl 1)))
       (local float knee (* (* kt (* kt kt))
                            (+ (* kt (- (* kt "6.0") "15.0")) "10.0")))
       ;; Geometry keeps the C2 quintic, while opacity rises earlier so
       ;; the shallow, diagonal shoulder is not faded out of existence.
       (local float gate_knee (pow knee "0.34"))
       ;; the FULL transform target -- fold at the full angle (primary
       ;; UP to face-on, the wrapped-around secondary DOWN), the
       ;; centring drop, the secondary's demagnification -- and a
       ;; straight LERP from the flat position to it, by the knee.
       ;; Composing a growing rotation with a growing drop made the
       ;; transition sag flat just above the band and then leap (the
       ;; hanging gap); the straight path keeps its density even, and
       ;; the endpoints are untouched: knee 1 is exactly the approved
       ;; interior, knee 0 the flat band
       (local float sa (sin u_fold))
       (local float ca (cos u_fold))
       (local float cy (- pv.y bh.y))
       (local float dx (- pv.x bh.x))
       ;; Only the direct image is an almost edge-on razor-thin plane.
       ;; Lensed passes keep the physical particle height so their upper
       ;; and lower arches retain volume.  Reusing u_lens here keeps the
       ;; pass contract compact: 0 is direct, 1 is strongly bent.
       (local float base_y (* cy u_thick))
       (local vec3 flat0 (vec3 dx base_y (- (fl 0) D)))
       (local vec3 rot3 (vec3 dx
                               (- (+ (* base_y ca) (* D sa)) u_drop)
                               (- (fl 0) (- (* D ca) (* base_y sa)))))
       ;; The secondary image is observed as a broad semicircle, not a
       ;; narrow teardrop.  Delay its horizontal magnification through
       ;; the fold so the two upper ends tuck inward before the round,
       ;; wide bottom reaches its full span.
       (local float wide_now (mix (fl 1) u_wide knee))
       (local vec3 full
              (* (vec3 (* rot3.x wide_now) rot3.y rot3.z) u_scale))
       (local vec3 off (mix flat0 full knee))
       ;; Sparse passes overlap with a small random lateral drift so the
       ;; visible density layers remain organic rather than concentric
       ;; cut-outs.  The far wing then fades continuously out to 1.5x.
       (local float sparse_span_mode (step (fl 0 50) u_sparse))
       (local float far_span_mode (step "2.50" u_sparse))
       (local float spread_rand
              (fract (* (sin (+ (* a_seed "91.7") (* a_r "12.31")))
                        "43758.5453")))
       (local float layer_spread
              (mix (fl 1) (mix "0.88" "1.12" spread_rand)
                   sparse_span_mode))
       (set! layer_spread
             (mix layer_spread (mix (fl 1) "1.5" spread_rand)
                  far_span_mode))
       (local float lens_soft_mode
              (* (step (fl 0 50) u_lens) sparse_span_mode))
       (local float vertical_rand
              (fract (* (sin (+ (* a_seed "173.3") (* a_r "7.91")))
                        "43758.5453")))
       (local float lens_spread
              (mix (fl 1) (mix "0.96" "1.16" vertical_rand)
                   lens_soft_mode))
       (set! off (vec3 (* off.x layer_spread)
                       (* off.y lens_spread) off.z))
       (set! pv (vec4 (+ bh.xyz off) pv.w))
       (local vec4 clip (* u_proj pv))
       ;; the conformal lens, aspect-corrected screen space (720/400):
       ;; r' = r + k/r keeps every image outside the photon ring
       (local vec2 nd (/ clip.xy clip.w))
       (local vec2 aa (vec2 (* nd.x "1.8") nd.y))
       (local float d (+ (length aa) "0.0001"))
       ;; The direct far half may remain visible outside the silhouette,
       ;; but it cannot redraw itself across the event horizon.  The near
       ;; half is left untouched and will be composited in the foreground.
       (local float far_side
              (smoothstep "-0.04" "0.06" (/ D a_r)))
       (local float direct_image
              (- (fl 1) (step (fl 0 50) u_lens)))
       (local float inside_shadow
              (- (fl 1) (smoothstep "0.350" "0.385" d)))
       ;; The foreground inner rim is itself a particle boundary: a
       ;; shallow ellipse with a broad stochastic feather, not a black
       ;; analytic shape laid over the finished image.
       (local float rim_x
              (clamp (/ (abs aa.x) "0.365") (fl 0) (fl 1)))
       (local float rim_y
              (* "-0.055"
                 (sqrt (max (fl 0) (- (fl 1) (* rim_x rim_x))))))
       (set! rim_y (+ rim_y (* (- a_seed (fl 0 50)) "0.022")))
       (local float front_keep
              (- (fl 1)
                 (smoothstep (- rim_y "0.025") (+ rim_y "0.025")
                             aa.y)))
       (local float inside_visible (* (- (fl 1) far_side) front_keep))
       (set! v_occ
             (mix (fl 1) inside_visible (* direct_image inside_shadow)))
       (local float k (* (* "0.03645" knee) u_lens))
       (local float dd (+ d (/ k d)))
       (local vec2 ab (* aa (/ dd d)))
       (set! gl_Position (vec4 (* (vec2 (/ ab.x "1.8") ab.y) clip.w)
                               clip.z clip.w))
       (set! gl_PointSize (min (+ (/ "30.0" clip.w) (* a_seed "1.5"))
                               "6.0"))
       ;; relativistic Doppler: Keplerian beta ~ r^-1/2, ~0.55c at the
       ;; inner edge; delta = 1 / (gamma (1 - beta cos theta))
       (local vec3 tang (vec3 (- (fl 0) (sin ang)) (fl 0) (cos ang)))
       (local float ct (dot tang (normalize (- u_eye wp))))
       (local float beta (/ "0.67" (sqrt a_r)))
       (local float gam (/ (fl 1) (sqrt (- (fl 1) (* beta beta)))))
       (set! v_dopp (/ (fl 1) (* gam (- (fl 1) (* beta ct)))))
       ;; Temperature falls quickly outside the inner edge.  This keeps
       ;; the white-hot strip narrow while the broad shoulders stay
       ;; copper and remain readable against the star field.
       (local float radial_t
              (clamp (/ (- a_r "1.5") "5.5") (fl 0) (fl 1)))
       (set! v_temp
             (+ "0.28" (* "0.85" (pow (- (fl 1) radial_t) "2.2"))))
       (set! v_seed a_seed)
       (set! v_lens (* knee u_lens))
       ;; a gated pass shows only the far side; gain scales the pass
       (local float sparse_mode (step (fl 0 50) u_sparse))
       (local float soft_mode
              (* (step "1.10" u_sparse)
                 (- (fl 1) (step "1.50" u_sparse))))
       (local float rare_mode (step "1.50" u_sparse))
       (local float far_mode (step "2.50" u_sparse))
       (local float sparse_lo
              (mix (mix (mix "0.955" "0.820" soft_mode)
                        "0.990" rare_mode)
                   "0.780" far_mode))
       (local float sparse_hi
              (mix (mix (mix "0.985" "0.940" soft_mode)
                        "0.998" rare_mode)
                   "0.930" far_mode))
       (local float sparse_keep
              (mix (fl 1) (smoothstep sparse_lo sparse_hi a_seed)
                   sparse_mode))
       ;; The rarest pass belongs only to the cool outer radii, making
       ;; broad lateral wings that are barely visible against space.
       (local float outer_lo (mix "4.60" "5.20" far_mode))
       (local float outer_hi (mix "6.30" "6.75" far_mode))
       (local float outer_keep
              (mix (fl 1) (smoothstep outer_lo outer_hi a_r) rare_mode))
       (local float wing_keep
              (mix (fl 1)
                   (smoothstep "0.55" "0.82" (abs (cos ang)))
                   rare_mode))
       (local float far_alpha
              (mix (fl 1) (mix (fl 1) "0.25" spread_rand) far_mode))
       ;; The readable direct disk must surrender its energy gradually;
       ;; otherwise its finite maximum radius draws a hard bright tip.
       (local float main_mode
              (* (- (fl 1) (step (fl 0 50) u_lens))
                 (- (fl 1) sparse_mode)))
       (local float main_edge
              (mix (fl 1)
                   (- (fl 1) (smoothstep "5.00" "6.95" a_r))
                   main_mode))
       (local float lens_main_mode
              (* (step (fl 0 50) u_lens) (- (fl 1) sparse_mode)))
       (local float lens_edge
              (mix (fl 1)
                   (- (fl 1) (smoothstep "5.10" "6.95" a_r))
                   lens_main_mode))
       (set! v_fade
             (* (* (* (mix (fl 1) gate_knee u_gate) u_gain)
                   sparse_keep)
                (* (* (* (* outer_keep wing_keep) far_alpha) main_edge)
                   lens_edge)))
       ;; the disk's own radial grooves: concentric emission rings.
       ;; Edge-on they compress into the band; folded over the hole
       ;; they read face-on -- each groove a ring of the flat disk
       ;; bent into the same line of sight
        (local float spiral1
               (sin (+ (+ (* a_r "7.0") (* ang "-3.0"))
                       (* u_t "0.28"))))
        (local float spiral2
               (sin (+ (+ (* a_r "3.7") (* ang "5.0"))
                       (* u_t "-0.16"))))
        (set! v_fade (* v_fade
                        (clamp (+ (+ "0.78" (* "0.14" spiral1))
                                  (* "0.08" spiral2))
                               "0.45" (fl 1))))))
   '((precision highp float)
     (uniform float u_t)
     (uniform float u_sparse)
     (varying float v_dopp)
     (varying float v_temp)
     (varying float v_seed)
     (varying float v_fade)
     (varying float v_lens)
     (varying float v_occ)
     (define (main) void
       (local vec2 pc (- gl_PointCoord (vec2 (fl 0 50) (fl 0 50))))
       (local float d2 (dot pc pc))
       (local float fall (- (fl 1) (smoothstep "0.02" "0.25" d2)))
       ;; Doppler beaming: I_obs = delta^4 I_emit (I/nu^3 invariant),
       ;; so the approaching side blazes and the receding side all but
       ;; goes out -- the asymmetry is the physics, not a tint
       (local float d4 (* (* v_dopp v_dopp) (* v_dopp v_dopp)))

       ;; delta^4 UNCLAMPED: the approaching inner edge really is an
       ;; order of magnitude brighter and the receding side really
       ;; does go out -- the asymmetry IS the physics, and Reinhard
       ;; absorbs the top end
       (local float beam d4)
       
       (local float flick (+ "0.85" (* "0.15"
                                        (sin (+ (* v_seed "40.0")
                                                (* u_t "3.0"))))))
       (local float shoulder_light
              (* (smoothstep "0.05" "0.30" v_lens)
                 (- (fl 1) (smoothstep "0.62" "0.88" v_lens))))
         (local float b (* (* (* (+ (* "0.060" beam) "0.018") flick)
                               (+ (+ (+ (fl 1) (* v_lens "0.26"))
                                     (* (- (fl 1) v_lens) "0.20"))
                                  (* shoulder_light "0.72")))
                            (* v_fade "1.18")))
       ;; spectral shift: T_obs = delta * T_emit, through a blackbody
       ;; ramp -- deep red, ember orange, white, blue-white
       (local float T (* v_temp v_dopp))

         (local vec3 c (mix (vec3 "0.55" "0.08" "0.02")
                            (vec3 (fl 1) "0.45" "0.12")
                            (smoothstep "0.15" "0.55" T)))
         (set! c (mix c (vec3 (fl 1) "0.97" "0.90")
                      (smoothstep "0.55" "1.10" T)))
         (set! c (mix c (vec3 "0.72" "0.82" (fl 1))
                      (smoothstep "1.10" "1.80" T)))

        ;; Strongly bent far-side particles make the white lens arc;
        ;; the direct near disk stays copper instead of becoming one
        ;; uniformly white hoop.
         (set! c (mix c (vec3 (fl 1) "0.95" "0.86")
                      (* (smoothstep "0.78" "0.99" v_lens) "0.30")))
       (set! gl_FragColor (vec4 c (* (* fall b) v_occ)))))))

;; ---- the disk: r biased inward, a thin wedge of height ----
(define buf (fx-buffer!))
(define data (fx-alloc! (* N 16)))
;; a fixnum-safe LCG: 999982 * 331 stays under 2^30, so every draw is
;; plain fixnum arithmetic (the classic 1103515245 multiplier promoted
;; every product to a bignum -- 800k bignum ops WAS the load hang)
(define seed 77)
(define (rnd!)
  (set! seed (remainder (+ (* seed 331) 197) 999983))
  (fl/ (fixnum->flonum seed) 999983.0))
(define (frac x) (fl- x (flfloor x)))
(let fill ((i 0))
  (when (< i N)
    (let* ((u (rnd!))
           (r (fl+ 1.5 (fl* 5.5 (fl* u (flsqrt u)))))
           (at (+ data (* i 16))))
      (%mem-f32-set! at r)
      ;; golden-ratio azimuths: low-discrepancy, and uncorrelated with
      ;; the LCG's radii (no Marsaglia spirals)
      (%mem-f32-set! (+ at 4)
                     (fl* 6.2831853
                          (frac (fl* (fixnum->flonum i) 0.61803398875))))
      (%mem-f32-set! (+ at 8) (fl* (fl* (fl- (fl+ (rnd!) (rnd!)) 1.0)
                                         0.09)
                                    r))
      (%mem-f32-set! (+ at 12) (rnd!)))
    (fill (+ i 1))))
(cmd-begin!)
(cmd-bind-buffer! buf)
(cmd-buffer-data! data (* N 16))
(cmd-flush!)

(define proj (m4-perspective 0.8 (/ 720.0 400.0) 0.1 100.0))
(define scene (fx-target-hdr! 720 400))
(define bloom (make-bloom 360 200))

(define (pass! fold scale wide drop gate lens thick sparse gain)
  (fx-uniform! disk-p 'u_fold fold)
  (fx-uniform! disk-p 'u_scale scale)
  (fx-uniform! disk-p 'u_wide wide)
  (fx-uniform! disk-p 'u_drop drop)
  (fx-uniform! disk-p 'u_gate gate)
  (fx-uniform! disk-p 'u_lens lens)
  (fx-uniform! disk-p 'u_thick thick)
  (fx-uniform! disk-p 'u_sparse sparse)
  (fx-uniform! disk-p 'u_gain gain)
  (cmd-draw-arrays! GL-POINTS 0 N))

(fx-loop!
 (lambda (t dt)
   (let* ((eye (v3 0.0 2.65 16.0))
          (view (m4-look-at eye (v3 0.0 0.0 0.0) (v3 0.0 1.0 0.0))))
     (cmd-unbind-texture! 0)
     (cmd-unbind-texture! 1)
     (cmd-depth! #f)
     (cmd-blend! #f)
     (fx-bind-target! scene)
     (fx-fullscreen-use! backdrop-q t)
     (fx-fullscreen-draw! backdrop-q)
     (cmd-blend! 'add)
     (fx-use! disk-p buf)
     (fx-uniform! disk-p 'u_view view)
     (fx-uniform! disk-p 'u_proj proj)
     (fx-uniform! disk-p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye))
     (fx-uniform! disk-p 'u_t t)
     ;; The setting diagram separates three structures.  The direct
     ;; disk stays flat and crosses in front.  Far-side light alone is
     ;; folded into the large upper primary image and the detached lower
     ;; secondary image; both hand back to the same flat band at the
     ;; sides through the shared quintic knee above.
     (pass! 1.50 1.18 1.00 1.50 1.0 1.0 1.30 1.25 0.065)
     (pass! -1.55 0.91 1.48 0.00 1.0 1.0 1.35 1.25 0.045)
     (pass! 1.50 1.00 1.00 1.50 1.0 1.0 1.00 0.0 0.82)
     (pass! -1.55 0.77 1.48 0.00 1.0 1.0 1.00 0.0 0.32)

     (fx-fullscreen-use! glow-veil-q t)
     (fx-fullscreen-draw! glow-veil-q)

     ;; Restore the exact circular shadow after additive lensing, then
     ;; place the observer-side disk in front of it.
     (cmd-blend! 'alpha)
     (fx-fullscreen-use! shadow-q t)
     (fx-fullscreen-draw! shadow-q)
     (cmd-blend! 'add)
     (fx-use! disk-p buf)
     ;; A nearly dark, exceptionally sparse outer wing extends well
     ;; beyond the readable disk before disappearing into the vacuum.
     (pass! 0.00 1.62 1.235 0.00 0.0 0.0 0.50 3.0 0.85)
     (pass! 0.00 1.60 1.22 0.00 0.0 0.0 0.54 2.0 0.050)
     (pass! 0.00 1.48 1.18 0.00 0.0 0.0 0.60 1.25 0.045)
     (pass! 0.00 1.35 1.15 0.00 0.0 0.0 0.64 1.25 0.058)
     (pass! 0.00 1.25 1.12 0.00 0.0 0.0 0.68 1.25 0.070)
     (pass! 0.00 1.13 1.12 0.00 0.0 0.0 0.45 0.0 0.40)
     (cmd-blend! #f)
     (bloom-run! bloom (fx-target-texture scene) 0.70 1.90)
     (bloom-composite! bloom (fx-target-texture scene) #f
                       'reinhard 1.07))))
