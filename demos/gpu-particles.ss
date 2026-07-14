;; GPU-compute fire: the physics is a @compute shader, and the
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
(import (rnrs) (web sx) (web js) (web dom) (gfx fx) (gfx gpu))

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
  (string-append
   "struct P { pos : vec2f, vel : vec2f, age : f32, life : f32 }\n"
   "struct Sim { dt : f32, t : f32, p1 : f32, p2 : f32 }\n"
   "@group(0) @binding(0) var<storage, read_write> ps : array<P>;\n"
   "@group(0) @binding(1) var<uniform> sim : Sim;\n"
   "fn h(n : f32) -> f32 { return fract(sin(n) * 43758.547); }\n"
   "@compute @workgroup_size(64)\n"
   "fn cs(@builtin(global_invocation_id) id : vec3u) {\n"
   "  let i = id.x;\n"
   "  if (i >= arrayLength(&ps)) { return; }\n"
   "  var p = ps[i];\n"
   "  p.age = p.age + sim.dt;\n"
   "  if (p.age >= p.life) {\n"
   "    let a = h(f32(i) * 12.9898 + sim.t);\n"
   "    let b = h(f32(i) * 78.233 + sim.t * 1.7);\n"
   "    let c = h(f32(i) * 37.719 + sim.t * 2.3);\n"
   "    let d = h(f32(i) * 93.989 + sim.t * 3.1);\n"
   ;; the flame hangs in mid-air, reborn on a filled disc: uniform
   ;; in radius, so the core is dense and the rim wispy; the disc's
   ;; radius beats, so the base is a round blob that pulses
   "    let R = 0.042 * (1.0 + 0.12 * sin(sim.t * 6.3)\n"
   "                         + 0.08 * sin(sim.t * 11.7));\n"
   "    let ang = 6.28319 * a;\n"
   "    let rad = R * b;\n"
   "    let x = rad * cos(ang);\n"
   "    p.pos = vec2f(x + 0.05 * sin(sim.t * 1.1),\n"
   "                  -0.46 + 0.8 * rad * sin(ang)\n"
   "                  + 0.03 * sin(sim.t * 0.7));\n"
   ;; fan outward from the small core; the contraction below reins
   ;; it back in, so the body swells to a teardrop and closes
   "    p.vel = vec2f(cos(ang) * 0.44 * b, 0.31 + 0.94 * d);\n"
   ;; the rim dies young, so the profile curves to a tip
   "    p.life = (0.35 + 1.05 * c) * (1.0 - 0.5 * b);\n"
   "    p.age = 0.0;\n"
   "    if (i % 61u == 0u) {\n"           ; an ember pops loose
   "      p.life = 2.0 + c;\n"
   "      p.vel = vec2f((a - 0.5) * 0.75, 1.1 + 1.1 * d);\n"
   "    }\n"
   "  } else {\n"
   "    let k = p.age / p.life;\n"
   "    p.vel.y = p.vel.y + (2.1 - 1.25 * k) * sim.dt;\n"
   "    p.vel.x = p.vel.x\n"
   "              + (1.25 * sin(p.pos.y * 5.0 + sim.t * 8.0)\n"
   "               + 0.69 * sin(p.pos.y * 11.0 - sim.t * 13.0))\n"
   "              * k * sim.dt;\n"
   "    p.vel = p.vel * (1.0 - 1.6 * sim.dt);\n"
   ;; the column narrows as it rises: contract x in POSITION --
   ;; a spring on the velocity oscillates too slowly to taper
   "    p.pos.x = p.pos.x * (1.0 - 2.0 * sim.dt);\n"
   "    p.pos = p.pos + p.vel * sim.dt;\n"
   "  }\n"
   "  ps[i] = p;\n"
   "}\n"))

(define RENDER
  (string-append
   "struct VOut { @builtin(position) pos : vec4f,\n"
   "              @location(0) c : vec4f }\n"
   "@vertex fn vs(@location(0) corner : vec2f,\n"
   "              @location(1) ppos : vec2f,\n"
   "              @location(2) pvel : vec2f,\n"
   "              @location(3) pal : vec2f) -> VOut {\n"
   "  var o : VOut;\n"
   "  let k = clamp(pal.x / max(pal.y, 0.001), 0.0, 1.0);\n"
   "  let ember = step(1.9, pal.y);\n"
   "  let size = (0.0035 + 0.013 * (1.0 - 0.6 * k))\n"
   "             * (1.0 - 0.7 * ember);\n"
   "  let w = corner * size;\n"
   ;; x * 400/720 squares the canvas back up, dots stay round
   "  o.pos = vec4f((ppos.x + w.x) * 0.5556, ppos.y + w.y,\n"
   ;; hotter = nearer: the young core burns through the old smoke
   "                mix(0.1 + 0.8 * k, 0.05, ember), 1.0);\n"
   "  let c1 = mix(vec3f(1.0, 0.96, 0.75), vec3f(1.0, 0.58, 0.10),\n"
   "               smoothstep(0.02, 0.14, k));\n"
   "  let c2 = mix(c1, vec3f(0.72, 0.12, 0.02),\n"
   "               smoothstep(0.4, 0.8, k));\n"
   "  var col = c2 * (1.0 - 0.85 * smoothstep(0.8, 1.0, k));\n"
   "  col = mix(col, vec3f(1.0, 0.8, 0.35) * (1.0 - 0.6 * k), ember);\n"
   "  o.c = vec4f(col, 1.0);\n"
   "  return o;\n"
   "}\n"
   "@fragment fn fs(@location(0) c : vec4f) -> @location(0) vec4f {\n"
   "  return c;\n"
   "}\n"))

;; the backdrop, one fullscreen quad: above the waterline, the halo
;; the flame throws into the air; below it, rippled water carrying
;; the flame's mirror -- a streak bent by two traveling waves --
;; everything flickering in the same phase as the fire
(define BG
  (string-append
   "struct Sim { dt : f32, t : f32, p1 : f32, p2 : f32 }\n"
   "@group(0) @binding(0) var<uniform> sim : Sim;\n"
   "struct VOut { @builtin(position) pos : vec4f,\n"
   "              @location(0) w : vec2f }\n"
   "@vertex fn vs(@location(0) p : vec2f) -> VOut {\n"
   "  var o : VOut;\n"
   "  o.pos = vec4f(p, 0.95, 1.0);\n"      ; behind every particle
   "  o.w = p;\n"
   "  return o;\n"
   "}\n"
   "@fragment fn fs(@location(0) w : vec2f) -> @location(0) vec4f {\n"
   "  let t = sim.t;\n"
   "  let flick = 0.85 + 0.10 * sin(t * 9.3) + 0.06 * sin(t * 15.7);\n"
   "  let wx = w.x * 1.8;\n"                ; aspect-true units
   "  let fx = 0.09 * sin(t * 1.1);\n"      ; the flame's drift, same phase
   "  var col = vec3f(0.015, 0.008, 0.025);\n"
   "  if (w.y > -0.68) {\n"                 ; air: the flame lights it
   "    let dx = wx - fx;\n"
   "    let dy = w.y + 0.30;\n"
   "    let r2 = dx * dx * 1.3 + dy * dy * 0.7;\n"
   "    col = col + vec3f(1.0, 0.5, 0.16)\n"
   "              * (0.22 * flick * exp(-r2 * 4.0));\n"
   "  } else {\n"                           ; water: ripples mirror it
   "    let d = -0.68 - w.y;\n"             ; depth below the line
   "    let rip = 0.020 * sin(wx * 34.0 - t * 2.6 + d * 25.0)\n"
   "            + 0.012 * sin(wx * 61.0 + t * 4.3);\n"
   "    let sx = wx - fx + rip * (1.0 + 8.0 * d);\n"
   "    let streak = exp(-sx * sx / (0.015 + 0.6 * d * d));\n"
   "    let shimmer = 0.75 + 0.25 * sin(wx * 47.0 + d * 90.0 - t * 5.0);\n"
   "    let heat = streak * exp(-d * 4.0) * shimmer * flick;\n"
   "    let glow = 0.30 * exp(-sx * sx * 1.5) * exp(-d * 2.5) * flick;\n"
   "    let line = 0.35 * exp(-d * 45.0) * exp(-sx * sx * 0.8) * flick;\n"
   "    col = vec3f(0.012, 0.02, 0.045)\n"
   "        + vec3f(1.0, 0.60, 0.20) * heat\n"
   "        + vec3f(1.0, 0.45, 0.15) * (glow + line);\n"
   "  }\n"
   "  return vec4f(col, 1.0);\n"
   "}\n"))

;; seed the fire mid-burn: random ages along the column, so the
;; flame is already standing when the first frame lands
(define seed 4321)
(define (rand01)
  (set! seed (remainder (+ (* seed 75) 74) 65537))
  (fl/ (fixnum->flonum seed) 65537.0))
(let init ((i 0))
  (when (< i N)
    (let* ((at (+ PBASE (* i 24)))
           (a (rand01))
           (b (rand01))
           (c (rand01))
           (ang (fl* 6.28319 a))
           (rad (fl* 0.042 b))
           (life (fl* (fl+ 0.35 (fl* 1.05 c)) (fl- 1.0 (fl* 0.5 b))))
           (age (fl* (rand01) life)))
      (%mem-f32-set! at (fl* rad (flcos ang)))
      (%mem-f32-set! (+ at 4) (fl+ (fl+ -0.46 (fl* 0.8 (fl* rad (flsin ang))))
                                   (fl* age 0.8)))
      (%mem-f32-set! (+ at 8) (fl* (fl* 0.44 b) (flcos ang)))
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
