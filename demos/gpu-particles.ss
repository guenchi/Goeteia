;; GPU-compute fire, five flames that gather and part: the
;; physics is a @compute shader, and the
;; particle buffer never leaves the GPU.  A storage buffer holds
;; 100,000 (pos, vel, age, life) records; each frame one dispatch
;; ages the flame -- buoyancy, a pinch toward the axis, two sine
;; winds that grow with age so the tips lick -- and respawns the
;; dead onto a filled disc hanging in mid-air -- dense at the core,
;; wispy at the rim, its radius beating, the whole base drifting
;; slowly (a hash of the invocation id is the random source), then
;; the SAME buffer feeds the render pass as a
;; per-instance vertex stream.  Color rides the age: white-hot at
;; birth, orange, deep red, gone; hotter particles take a smaller
;; depth value, so the core burns through the smoke without any
;; blending.  One in 61 respawns as an ember and pops loose.
;; A second pipeline draws the backdrop: the halo the flame throws
;; into the air, and below the waterline its mirror on rippled
;; water, bent by traveling waves, flickering in the same phase.
;; The CPU's whole per-frame contribution is 16 bytes of uniforms.
;; Needs a WebGPU browser.
(import (rnrs) (web sx) (web js) (web dom) (gfx fx) (gfx gpu) (gfx wgsl))

;; re-running (or leaving) a tab must retire the previous loop; GL
;; demos bump this through fx-init!, a WebGPU demo bumps it itself
(js-eval "globalThis.__goeteia_fx_gen = (globalThis.__goeteia_fx_gen || 0) + 1")

;; the demo mounts its own canvas where the hero usually lives --
;; or, without WebGPU, says what it would have shown
(define gpu? (js-truthy? (js-eval "!!navigator.gpu")))
(sx-mount (get-element-by-id "live")
  (if gpu?
      (sx (div (@ (class "hero"))
            (canvas (@ (id "c") (width "720") (height "400")
                       (style "display:block;width:100%;max-width:40em;border-radius:12px")))))
      (sx (div (@ (class "hero"))
            (p "This demo runs the physics in a WebGPU compute shader - it needs a WebGPU browser (current Chrome / Edge / Safari).")))))

(define N 100000)
(define PBYTES (* N 24))                ; vec2 pos + vec2 vel + age + life
(define UBASE 4096)
(define PBASE 8192)
(let ((need (- (+ PBASE PBYTES) (* 65536 (%mem-size)))))
  (when (> need 0)
    (%mem-grow (quotient (+ need 65535) 65536))))

(define CS
  (wgsl-compute->string
   '((struct P ((vec2 pos) (vec2 vel) (float age) (float life)))
     (storage ps (array P))
     (uniform float dt)
     (uniform float t)
     (uniform float p1)
     (uniform float p2)
     (workgroup 64)
     (define (h (float n)) float
       (return (fract (* (sin n) "43758.547"))))
     (define (main) void
       (local uint i gid.x)
       (if (>= i (array-length ps)) (return))
       (local P p (at ps i))
       ;; five flames in a dance: each orbits the centre on a
       ;; figure-eight (x = R cos th, y ~ sin 2th), the swirl's speed
       ;; itself wobbles, and a slow 24s breath gathers all five into
       ;; one blaze before opening the ring again -- crossing,
       ;; overtaking, never a straight line
       (local float fi (float (% i 5)))
       (local float ph (* fi "1.25664"))
       (local float gather (- (fl 0 50)
                              (* (fl 0 50) (cos (* t "0.26")))))
       (local float th (+ (* t "0.55")
                          (* "0.8" (sin (* t "0.13"))) ph))
       (local float R (* "0.55" gather))
       (local float bx (+ (* R (cos th))
                          (* "0.03" (sin (+ (* t "1.7")
                                            (* ph (fl 3)))))))
       (local float by (+ (* gather (+ (* "0.09" (sin (* (fl 2) th)))
                                       "0.05"))
                          (* "0.04" (sin (+ (* t "2.2") ph)))))
       (set! p.age (+ p.age dt))
       (if-else (>= p.age p.life)
         ((local float a (h (+ (* (float i) "12.9898") t)))
          (local float b (h (+ (* (float i) "78.233") (* t "1.7"))))
          (local float c (h (+ (* (float i) "37.719") (* t "2.3"))))
          (local float d (h (+ (* (float i) "93.989") (* t "3.1"))))
          ;; the flame hangs in mid-air, reborn on a filled disc:
          ;; uniform in radius, so the core is dense and the rim
          ;; wispy; the disc's radius beats, so the base pulses
          (local float R (* "0.042" (+ (fl 1)
                                       (* "0.12" (sin (* t "6.3")))
                                       (* "0.08" (sin (* t "11.7"))))))
          (local float ang (* "6.28319" a))
          (local float rad (* R b))
          (local float x (* rad (cos ang)))
          (set! p.pos (vec2 (+ x bx)
                            (+ "-0.46" by
                               (* "0.8" (* rad (sin ang))))))
          ;; fan outward from the small core; the contraction below
          ;; reins it back in: the body swells to a teardrop
          (set! p.vel (vec2 (* (cos ang) (* "0.44" b))
                            (+ "0.31" (* "0.94" d))))
          ;; the rim dies young, so the profile curves to a tip
          (set! p.life (* (+ "0.35" (* "1.05" c))
                          (- (fl 1) (* "0.5" b))))
          (set! p.age (fl 0))
          (if (== (% i 61) 0)             ; an ember pops loose
              (set! p.life (+ (fl 2) c))
              (set! p.vel (vec2 (* (- a (fl 0 50)) "0.75")
                                (+ "1.1" (* "1.1" d))))))
         ((local float k (/ p.age p.life))
          (set! p.vel.y (+ p.vel.y (* (- "2.1" (* "1.25" k)) dt)))
          (set! p.vel.x (+ p.vel.x
                           (* (+ (* "1.25" (sin (+ (* p.pos.y (fl 5))
                                                   (* t (fl 8))
                                                   (* fi "2.1"))))
                                 (* "0.69" (sin (- (* p.pos.y (fl 11))
                                                   (* t (fl 13))))))
                              k dt)))
          (set! p.vel (* p.vel (- (fl 1) (* "1.6" dt))))
          ;; the column narrows as it rises: contract x toward the
          ;; particle's OWN flame axis (not the screen centre)
          (set! p.pos.x (+ bx (* (- p.pos.x bx)
                                 (- (fl 1) (* "2.0" dt)))))
          (set! p.pos (+ p.pos (* p.vel dt)))))
       (set! (at ps i) p)))))

(define RENDER
  (wgsl->string
   '((attribute vec2 corner)
     (attribute vec2 ppos)
     (attribute vec2 pvel)
     (attribute vec2 pal)
     (varying vec4 v_c)
     (define (main) void
       (local float k (clamp (/ pal.x (max pal.y "0.001"))
                             (fl 0) (fl 1)))
       (local float ember (step "1.9" pal.y))
       (local float size (* (+ "0.0035" (* "0.013" (- (fl 1) (* "0.6" k))))
                            (- (fl 1) (* "0.7" ember))))
       (local vec2 w (* corner size))
       ;; x * 400/720 squares the canvas back up, dots stay round;
       ;; hotter = nearer: the young core burns through the smoke
       (set! gl_Position (vec4 (* (+ ppos.x w.x) "0.5556")
                               (+ ppos.y w.y)
                               (mix (+ (fl 0 10) (* (fl 0 80) k))
                                    "0.05" ember)
                               (fl 1)))
       (local vec3 c1 (mix (vec3 (fl 1) "0.96" "0.75")
                           (vec3 (fl 1) "0.58" "0.10")
                           (smoothstep "0.02" "0.14" k)))
       (local vec3 c2 (mix c1 (vec3 "0.72" "0.12" "0.02")
                           (smoothstep "0.4" "0.8" k)))
       (local vec3 col (* c2 (- (fl 1)
                                (* "0.85" (smoothstep "0.8" (fl 1) k)))))
       (set! col (mix col (* (vec3 (fl 1) "0.8" "0.35")
                             (- (fl 1) (* "0.6" k)))
                      ember))
       (set! v_c (vec4 col (fl 1)))))
   '((define (main) void
       (set! gl_FragColor v_c)))))

(define BG
  (wgsl->string
   '((attribute vec2 apos)
     (uniform float dt)                  ; the Sim struct, all four
     (uniform float t)                   ; members, so the layout
     (uniform float p1)                  ; matches the shared buffer
     (uniform float p2)
     (varying vec2 v_w)
     (define (main) void
       (set! gl_Position (vec4 apos.x apos.y "0.95" (fl 1)))
       (set! v_w apos)))
   '((define (main) void
       (local float flick (+ "0.85"
                             (* "0.10" (sin (* t "9.3")))
                             (* "0.06" (sin (* t "15.7")))))
       (local float wx (* v_w.x "1.8"))  ; aspect-true units
       (local float fx (* "0.09" (sin (* t "1.1"))))
       (local vec3 col (vec3 "0.015" "0.008" "0.025"))
       (if-else (> v_w.y "-0.68")
         ;; air: the flame lights it
         ((local float dx (- wx fx))
          (local float dy (+ v_w.y "0.30"))
          (local float r2 (+ (* dx dx "1.3") (* dy dy "0.7")))
          (set! col (+ col (* (vec3 (fl 1) (fl 0 50) "0.16")
                              (* "0.22" flick
                                 (exp (- (* r2 (fl 4)))))))))
         ;; water: ripples mirror it
         ((local float d (- "-0.68" v_w.y))
          (local float rip (+ (* "0.020" (sin (+ (- (* wx "34.0")
                                                    (* t "2.6"))
                                                 (* d "25.0"))))
                              (* "0.012" (sin (+ (* wx "61.0")
                                                 (* t "4.3"))))))
          (local float sx (+ (- wx fx)
                             (* rip (+ (fl 1) (* (fl 8) d)))))
          (local float streak (exp (- (/ (* sx sx)
                                         (+ "0.015" (* "0.6" d d))))))
          (local float shimmer (+ "0.75"
                                  (* "0.25" (sin (- (+ (* wx "47.0")
                                                       (* d "90.0"))
                                                    (* t (fl 5)))))))
          (local float heat (* streak (exp (- (* d (fl 4))))
                               shimmer flick))
          (local float glow (* "0.30" (exp (- (* sx sx "1.5")))
                               (exp (- (* d "2.5"))) flick))
          (local float line (* "0.35" (exp (- (* d "45.0")))
                               (exp (- (* sx sx "0.8"))) flick))
          (set! col (+ (vec3 "0.012" "0.02" "0.045")
                       (* (vec3 (fl 1) "0.60" "0.20") heat)
                       (* (vec3 (fl 1) "0.45" "0.15") (+ glow line))))))
       (set! gl_FragColor (vec4 col (fl 1)))))))

;; seed the fire mid-burn: random ages along the column, so the
;; flame is already standing when the first frame lands
(define seed 4321)
(define (rand01)
  (set! seed (remainder (+ (* seed 75) 74) 65537))
  (fl/ (fixnum->flonum seed) 65537.0))
;; a 256-entry cos/sin table: the seeded angles live one life cycle
;; before the GPU respawns everything, so 1.4-degree quantization is
;; invisible -- and the million-particle fill drops three polynomial
;; trig calls per particle to two memory reads
(define COSTAB (fx-alloc! 2048))
(let tab ((k 0))
  (when (< k 256)
    (let ((a (fl* 0.02454369 (fixnum->flonum k))))
      (%mem-f32-set! (+ COSTAB (* k 8)) (flcos a))
      (%mem-f32-set! (+ COSTAB (* k 8) 4) (flsin a)))
    (tab (+ k 1))))
(let init ((i 0))
  (when (< i N)
    (let* ((at (+ PBASE (* i 24)))
           (a (rand01))
           (b (rand01))
           (c (rand01))
           (ti (* 8 (%fl->fx (fl* 255.9 a))))
           (co (%mem-f32-ref (+ COSTAB ti)))
           (si (%mem-f32-ref (+ COSTAB ti 4)))
           (rad (fl* 0.042 b))
           (life (fl* (fl+ 0.35 (fl* 1.05 c)) (fl- 1.0 (fl* 0.5 b))))
           (age (fl* (rand01) life)))
      (%mem-f32-set! at (fl* rad co))
      (%mem-f32-set! (+ at 4) (fl+ (fl+ -0.46 (fl* 0.8 (fl* rad si)))
                                   (fl* age 0.8)))
      (%mem-f32-set! (+ at 8) (fl* (fl* 0.44 b) co))
      (%mem-f32-set! (+ at 12) 0.5)
      (%mem-f32-set! (+ at 16) age)
      (%mem-f32-set! (+ at 20) life))
    (init (+ i 1))))

(define ready #f)
(define uploaded #f)
(when gpu?
  (gpu-attach! (get-element-by-id "c")
             (lambda ()
               ;; slot 0: the unit triangle; 1: the particle storage
               (gpu-buffer! 0 24)
               (gpu-storage! 1 PBYTES)
               (gpu-uniforms! 2 16)
               (gpu-compute! 3 CS)
               (gpu-compute-group! 4 3 1 2)
               (gpu-pipeline2! 5 RENDER
                               8 "float32x2"          ; per vertex
                               24 "float32x2,float32x2,float32x2") ; per particle
               ;; 6: the backdrop pipeline; 7: its quad; 8: its uniforms
               (gpu-pipeline! 6 BG 8 "float32x2")
               (gpu-buffer! 7 48)
               (gpu-bindgroup! 8 6 2)
               (set! ready #t))))

;; the unit triangle the instances stamp
(define TBASE 2048)
(let corner ((k 0) (vs '(0.0 1.0  -0.87 -0.5  0.87 -0.5)))
  (unless (null? vs)
    (%mem-f32-set! (+ TBASE (* k 4)) (car vs))
    (corner (+ k 1) (cdr vs))))

;; the backdrop quad: two triangles over the whole canvas
(define QBASE 2560)
(let corner ((k 0) (vs '(-1.0 -1.0  1.0 -1.0  1.0 1.0
                         -1.0 -1.0  1.0 1.0  -1.0 1.0)))
  (unless (null? vs)
    (%mem-f32-set! (+ QBASE (* k 4)) (car vs))
    (corner (+ k 1) (cdr vs))))

(fx-ticks!
 (lambda (t dt)
   (when ready
     (let ((dtc (if (fl<? dt 0.05) dt 0.05)))
       (%mem-f32-set! UBASE dtc)
       (%mem-f32-set! (+ UBASE 4) t))
     (gpu-begin!)
     (unless uploaded
       (gpu-buffer-data! 0 TBASE 24)
       (gpu-buffer-data! 1 PBASE PBYTES)
       (gpu-buffer-data! 7 QBASE 48)
       (set! uploaded #t))
     (gpu-buffer-data! 2 UBASE 16)
     ;; physics first (its own compute pass), then the frame
     (gpu-dispatch! 3 4 (quotient (+ N 63) 64))
     (gpu-clear! 0.02 0.01 0.03 1.0)
     (gpu-use-pipeline! 5)              ; the flame needs no bind group
     (gpu-bind-vbuf! 0)
     (gpu-bind-vbuf2! 1)
     (gpu-draw-instanced! 3 N)
     ;; the backdrop last: depth keeps it behind every particle
     (gpu-use-pipeline! 6)
     (gpu-set-group! 8)
     (gpu-bind-vbuf! 7)
     (gpu-draw! 6)
     (gpu-flush!))))
