;; A black hole's accretion disk, two hundred thousand particles whose
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

(define N 200000)

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
     (uniform float u_image)             ; 0 primary, 1 secondary
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
       ;; behind (the conformal gate, the compression blend, the
       ;; secondary's fade) ramps by ABSOLUTE depth -- that keeps the
       ;; image concentric on the shadow.  Only the fold ANGLE ramps
       ;; by azimuth (D over the ring's own radius): every ring
       ;; completes its fold the same angular distance from the side,
       ;; so the arc ends bend down in a smooth knee proportional to
       ;; the ring and merge tangent into the flat band
       (local float behind (smoothstep (fl 0) "2.0" D))
       (local float knee (smoothstep (fl 0) "0.55" (/ D a_r)))
       ;; primary folds UP to near face-on -- each far semicircle a
       ;; half-ring; the secondary (light that wrapped the other way)
       ;; folds DOWN, demagnified, under the shadow
       (local float fa (* (mix "1.50" "-1.50" u_image) knee))
       (local float cy (- pv.y bh.y))
       (local float sa (sin fa))
       (local float ca (cos fa))
       (local vec3 off (vec3 (- pv.x bh.x)
                             (+ (* cy ca) (* D sa))
                             (- (fl 0) (- (* D ca) (* cy sa)))))
       ;; each disk ring images as an arc CONCENTRIC with the shadow
       ;; (the color-banded diagrams): fold to face-on, then an affine
       ;; radial map -- inner edge at the ring, the outermost ring
       ;; arcing to ~2.2x the ring above and ~1.8x below.  The flat
       ;; band (behind = 0) keeps its length
       (local float L (max (length off) "0.001"))
       (local float L2 (+ (mix "1.5" "1.4" u_image)
                          (* (mix "0.78" "0.58" u_image)
                             (max (- L "1.5") (fl 0)))))
       (set! off (* off (mix (fl 1) (/ L2 L) behind)))
       (set! pv (vec4 (+ bh.xyz off) pv.w))
       (local vec4 clip (* u_proj pv))
       ;; the conformal lens, aspect-corrected screen space (720/400):
       ;; r' = r + k/r keeps every image outside the photon ring
       (local vec2 nd (/ clip.xy clip.w))
       (local vec2 aa (vec2 (* nd.x "1.8") nd.y))
       (local float d (+ (length aa) "0.0001"))
       (local float k (* "0.038" behind))
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
       ;; the secondary image shows only the far side, and fainter
       (set! v_fade (mix (fl 1) (* behind "0.55") u_image))
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
(define seed 77)
(define (rnd!)
  (set! seed (remainder (+ (* seed 1103515245) 12345) 2147483648))
  (fl/ (fixnum->flonum (remainder seed 100000)) 100000.0))
(let fill ((i 0))
  (when (< i N)
    (let* ((u (rnd!))
           (r (fl+ 1.5 (fl* 5.5 (fl* u (flsqrt u)))))
           (at (+ data (* i 16))))
      (%mem-f32-set! at r)
      (%mem-f32-set! (+ at 4) (fl* 6.2831853 (rnd!)))
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
     ;; primary image, then the wrapped-around secondary under the hole
     (fx-uniform! disk-p 'u_image 0.0)
     (cmd-draw-arrays! GL-POINTS 0 N)
     (fx-uniform! disk-p 'u_image 1.0)
     (cmd-draw-arrays! GL-POINTS 0 N)
     (cmd-blend! #f))))
