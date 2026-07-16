;; A black hole's accretion disk, a million particles whose
;; physics is arithmetic in the vertex shader: each particle is four
;; numbers (radius, phase, height, seed) and its position is a pure
;; function of time -- Keplerian shear, the inner disk lapping the
;; outer.  The lensing is a conformal trick: in screen space every
;; point slides out along r' = r + k/r, which has a minimum at 2*sqrt(k)
;; -- so no image lands inside the photon ring, the shadow falls out
;; of the arithmetic, and light crowds the ring by itself.  The
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
        (gfx mat) (gfx mesh))

;; the demo mounts its own canvas where the hero usually lives
(sx-mount (get-element-by-id "live")
  (sx (div (@ (class "hero"))
        (canvas (@ (id "c") (width "720") (height "400")
                   (style "display:block;width:100%;max-width:40em;border-radius:12px"))))))

(fx-init! (get-element-by-id "c"))

(define N 1000000)

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
     (uniform float u_drop)              ; its centring drop
     (uniform float u_gate)              ; 1: far side only
     (uniform float u_gain)              ; its brightness
     (varying float v_dopp)
     (varying float v_temp)
     (varying float v_seed)
     (varying float v_fade)
     (define (main) void
       ;; Kepler: the angular rate falls as r^-3/2
       (local float ang (+ a_ph (/ (* u_t "2.6") (* a_r (sqrt a_r)))))
       (local vec3 wp (vec3 (* a_r (cos ang)) a_h (* a_r (sin ang))))
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
       ;; Wider (0.75) so the bend starts farther out
       (local float kt (clamp (/ (/ D a_r) "0.75") (fl 0) (fl 1)))
       (local float knee (* (* kt (* kt kt))
                            (+ (* kt (- (* kt "6.0") "15.0")) "10.0")))
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
       (local vec3 flat0 (vec3 dx cy (- (fl 0) D)))
       (local vec3 rot3 (vec3 dx
                              (- (+ (* cy ca) (* D sa)) u_drop)
                              (- (fl 0) (- (* D ca) (* cy sa)))))
       (local vec3 full (* rot3 u_scale))
       (local vec3 off (mix flat0 full knee))
       (set! pv (vec4 (+ bh.xyz off) pv.w))
       (local vec4 clip (* u_proj pv))
       ;; the conformal lens, aspect-corrected screen space (720/400):
       ;; r' = r + k/r keeps every image outside the photon ring
       (local vec2 nd (/ clip.xy clip.w))
       (local vec2 aa (vec2 (* nd.x "1.8") nd.y))
       (local float d (+ (length aa) "0.0001"))
       (local float k (* "0.038" knee))
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
       ;; the emitted temperature falls with radius (normalized)
       (set! v_temp (mix (fl 1) "0.35" (/ (- a_r "1.5") "5.5")))
       (set! v_seed a_seed)
       ;; a gated pass shows only the far side; gain scales the pass
       (set! v_fade (* (mix (fl 1) knee u_gate) u_gain))
       ;; the disk's own radial grooves: concentric emission rings.
       ;; Edge-on they compress into the band; folded over the hole
       ;; they read face-on -- each groove a ring of the flat disk
       ;; bent into the same line of sight
       (local float g1 (sin (* a_r "9.0")))
       (local float g2 (sin (+ (* a_r "23.0") "1.7")))
       (set! v_fade (* v_fade
                       (clamp (+ (+ "0.42" (* "0.38" g1)) (* "0.20" g2))
                              "0.15" (fl 1))))))
   '((precision highp float)
     (uniform float u_t)
     (varying float v_dopp)
     (varying float v_temp)
     (varying float v_seed)
     (varying float v_fade)
     (define (main) void
       (local vec2 pc (- gl_PointCoord (vec2 (fl 0 50) (fl 0 50))))
       (local float d2 (dot pc pc))
       (local float fall (- (fl 1) (smoothstep "0.02" "0.25" d2)))
       ;; Doppler beaming: I_obs = delta^4 I_emit (I/nu^3 invariant),
       ;; so the approaching side blazes and the receding side all but
       ;; goes out -- the asymmetry is the physics, not a tint
       (local float d4 (* (* v_dopp v_dopp) (* v_dopp v_dopp)))
       (local float flick (+ "0.85" (* "0.15"
                                       (sin (+ (* v_seed "40.0")
                                               (* u_t "3.0"))))))
       (local float b (* (* (+ (* "0.11" d4) "0.02") flick) v_fade))
       ;; spectral shift: T_obs = delta * T_emit, through a blackbody
       ;; ramp -- deep red, ember orange, white, blue-white
       (local float T (* v_temp v_dopp))
       (local vec3 c (mix (vec3 "0.55" "0.08" "0.02")
                          (vec3 (fl 1) "0.45" "0.12")
                          (smoothstep "0.15" "0.55" T)))
       (set! c (mix c (vec3 (fl 1) "0.97" "0.92")
                    (smoothstep "0.55" "1.10" T)))
       (set! c (mix c (vec3 "0.72" "0.82" (fl 1))
                    (smoothstep "1.10" "1.80" T)))
       (set! gl_FragColor (vec4 c (* fall b)))))))

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
                                        0.05)
                                   r))
      (%mem-f32-set! (+ at 12) (rnd!)))
    (fill (+ i 1))))
(cmd-begin!)
(cmd-bind-buffer! buf)
(cmd-buffer-data! data (* N 16))
(cmd-flush!)

(define proj (m4-perspective 0.8 (/ 720.0 400.0) 0.1 100.0))

(define (pass! fold scale drop gate gain)
  (fx-uniform! disk-p 'u_fold fold)
  (fx-uniform! disk-p 'u_scale scale)
  (fx-uniform! disk-p 'u_drop drop)
  (fx-uniform! disk-p 'u_gate gate)
  (fx-uniform! disk-p 'u_gain gain)
  (cmd-draw-arrays! GL-POINTS 0 N))

(fx-loop!
 (lambda (t dt)
   (let* ((a (fl* 0.045 t))
          (eye (v3 (fl* 16.0 (flsin a)) 2.1 (fl* 16.0 (flcos a))))
          (view (m4-look-at eye (v3 0.0 0.0 0.0) (v3 0.0 1.0 0.0))))
     (cmd-clear! 0.004 0.004 0.012 1.0)
     (cmd-depth! #f)
     (cmd-blend! 'add)
     (fx-use! disk-p buf)
     (fx-uniform! disk-p 'u_view view)
     (fx-uniform! disk-p 'u_proj proj)
     (fx-uniform! disk-p 'u_eye (v3-x eye) (v3-y eye) (v3-z eye))
     (fx-uniform! disk-p 'u_t t)
     ;; three images: the primary fold, the wrapped-around secondary
     ;; under the hole, and a fainter outer halo ringing the arch
     (pass! 1.50 1.0 1.5 0.0 1.0)
     (pass! -0.72 0.48 0.0 1.0 0.55)
     (pass! 1.50 1.30 1.5 1.0 0.32)
     (pass! 1.50 1.58 1.5 1.0 0.18)
     (pass! 1.50 1.85 1.5 1.0 0.09)
     (cmd-blend! #f))))
