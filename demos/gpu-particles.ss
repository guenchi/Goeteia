;; GPU-compute particles: the physics is a @compute shader, and the
;; particle buffer never leaves the GPU.  A storage buffer holds
;; 100,000 (pos, vel) pairs; each frame one dispatch integrates
;; gravity and respawns the fallen (a hash of the invocation id is
;; the random source), then the SAME buffer feeds the render pass as
;; a per-instance vertex stream -- gpu-storage! carries both usages.
;; The CPU's whole per-frame contribution is 16 bytes of uniforms.
;; This is (gfx gl)'s transform-feedback trick, the WebGPU way.
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
(define PBYTES (* N 16))                ; vec2 pos + vec2 vel
(define UBASE 4096)
(define PBASE 8192)
(let ((need (- (+ PBASE PBYTES) (* 65536 (%mem-size)))))
  (when (> need 0)
    (%mem-grow (quotient (+ need 65535) 65536))))

(define CS
  (string-append
   "struct P { pos : vec2f, vel : vec2f }\n"
   "struct Sim { dt : f32, seed : f32, p1 : f32, p2 : f32 }\n"
   "@group(0) @binding(0) var<storage, read_write> ps : array<P>;\n"
   "@group(0) @binding(1) var<uniform> sim : Sim;\n"
   "@compute @workgroup_size(64)\n"
   "fn cs(@builtin(global_invocation_id) id : vec3u) {\n"
   "  let i = id.x;\n"
   "  if (i >= arrayLength(&ps)) { return; }\n"
   "  var p = ps[i];\n"
   "  p.vel.y = p.vel.y - 1.8 * sim.dt;\n"
   "  p.pos = p.pos + p.vel * sim.dt;\n"
   "  if (p.pos.y < -1.02) {\n"
   "    let h = fract(sin(f32(i) * 12.9898 + sim.seed) * 43758.547);\n"
   "    let g = fract(sin(f32(i) * 78.233 + sim.seed * 1.7) * 12543.123);\n"
   "    p.pos = vec2f((h - 0.5) * 0.06, -0.9);\n"
   "    p.vel = vec2f((g - 0.5) * 1.5, 1.2 + h * 1.2);\n"
   "  }\n"
   "  ps[i] = p;\n"
   "}\n"))

(define RENDER
  (string-append
   "struct VOut { @builtin(position) pos : vec4f,\n"
   "              @location(0) c : vec4f }\n"
   "@vertex fn vs(@location(0) corner : vec2f,\n"
   "              @location(1) ppos : vec2f,\n"
   "              @location(2) pvel : vec2f) -> VOut {\n"
   "  var o : VOut;\n"
   "  o.pos = vec4f(corner * 0.004 + ppos, 0.0, 1.0);\n"
   "  let s = clamp(length(pvel) * 0.45, 0.0, 1.0);\n"
   "  o.c = vec4f(0.95, 0.55 + 0.25 * s, 0.2 + 0.65 * s, 1.0);\n"
   "  return o;\n"
   "}\n"
   "@fragment fn fs(@location(0) c : vec4f) -> @location(0) vec4f {\n"
   "  return c;\n"
   "}\n"))

;; seed the flock: spread over the canvas with upward velocities
(define seed 4321)
(define (rand01)
  (set! seed (remainder (+ (* seed 75) 74) 65537))
  (fl/ (fixnum->flonum seed) 65537.0))
(let init ((i 0))
  (when (< i N)
    (let ((at (+ PBASE (* i 16))))
      (%mem-f32-set! at (fl- (fl* 2.0 (rand01)) 1.0))
      (%mem-f32-set! (+ at 4) (fl- (fl* 2.0 (rand01)) 1.0))
      (%mem-f32-set! (+ at 8) (fl* 0.8 (fl- (rand01) 0.5)))
      (%mem-f32-set! (+ at 12) (fl* 1.2 (rand01))))
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
                               16 "float32x2,float32x2") ; per particle
               (set! ready #t))))

;; the unit triangle the instances stamp
(define TBASE 2048)
(let corner ((k 0) (vs '(0.0 1.0  -0.87 -0.5  0.87 -0.5)))
  (unless (null? vs)
    (%mem-f32-set! (+ TBASE (* k 4)) (car vs))
    (corner (+ k 1) (cdr vs))))

(fx-ticks!
 (lambda (t dt)
   (when ready
     (let ((dtc (if (fl<? dt 0.05) dt 0.05)))
       (%mem-f32-set! UBASE dtc)
       (%mem-f32-set! (+ UBASE 4) (fl* 0.1 t)))
     (gpu-begin!)
     (unless uploaded
       (gpu-buffer-data! 0 TBASE 24)
       (gpu-buffer-data! 1 PBASE PBYTES)
       (set! uploaded #t))
     (gpu-buffer-data! 2 UBASE 16)
     ;; physics first (its own compute pass), then the frame
     (gpu-dispatch! 3 4 (quotient (+ N 63) 64))
     (gpu-clear! 0.02 0.02 0.05 1.0)
     (gpu-use-pipeline! 5)              ; render needs no bind group
     (gpu-bind-vbuf! 0)
     (gpu-bind-vbuf2! 1)
     (gpu-draw-instanced! 3 N)
     (gpu-flush!))))
